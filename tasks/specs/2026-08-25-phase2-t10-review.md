# Phase 2 T10 — Fable adversarial review of the RT diff (2ca7aea..294c8c3)

**Reviewer**: Fable · xhigh · 2026-08-26. Scope: TapeTransportRT, AppTapeTransport,
TapeTransportManager, TapeExporter, ProcessTapController/AudioEngine integration, panel-model
engine wiring, URL scheme, and the five T3 invariants. Read-only review; no builds run (disk
constraint) — the full-suite gate runs separately. Findings ranked; "test exists?" stated for
every Critical/Important. Verified-correct list at the end.

---

## C1 — CRITICAL: the output gate, fed the substituted tape peak, records SILENCE over live audio

**What the user does**: arms a tape, rewinds, then stops/brakes the tape (or plays a quiet
passage longer than the gate's silence hold) while the app keeps playing live.
**What they hear later**: rewinding to — or retro-record exporting — that span yields silence,
then a fade-in, where the app was audibly playing. The recording is permanently poisoned.
**Why the code produces it**: the gain stage in `processMappedBuffers` multiplies the live
input by `outputGateMultiplier` *before* the ring write (`gain = currentVol × crossfade ×
outputGate`), and E19's substitution (`audibleInputPeak`, ProcessTapController.swift:1608)
feeds the gate the **tape output peak** whenever the transport is non-live. A stopped tape has
output peak 0 → `advanceOutputGate` re-arms after `silenceHoldSamples` → multiplier 0 → the
gain stage zeroes the live input → `writeAndRender` copies those zeros into the ring. The gate
can only reopen from a non-silent *tape* peak, so it stays closed for the whole stopped period
regardless of how loud the live input is. This directly violates Q4's "the ring write never
stops … the record head and the play head are independent" and E21's timeline promise: the
timeline stays continuous but its *content* is destroyed.

Two structural observations that sharpen the fix:
1. **The gate no longer needs the substitution to protect playback.** E19's stated fear —
   "the gate would re-arm and mute the transport playback" — cannot happen in the built
   architecture: when non-live, the transport *replaces* the buffer after the gain stage, so
   the gate multiplier never touches what the user hears. The gate's only remaining effect
   while non-live is on the recording. Feeding it the tape peak protects nothing and poisons
   the tape.
2. **Corollary, same root cause**: hitting LIVE from a stopped tape fades into a buffer the
   closed gate has zeroed — the user gets 50 ms fade-to-silence, then the gate's attack ramp,
   instead of live audio. The LIVE button audibly misbehaves on the stop→LIVE path.

**Fix direction** (T5 owner's call): the gate's input peak while non-live should be the LIVE
input peak (its job is gating what enters the ring and the live path), or
`max(livePeak, tapePeak)`; the *meter* keeps the tape-peak substitution. One-line change at
the `gateInputPeak` site; the `audibleInputPeak` helper then serves the meter only.

**Test exists?** No. `audiblePeakSubstitutesTapeOutputWhenEngaged` covers only the
loud-playback case; the stopped/quiet case — the one that bites — is uncovered, and no test
drives `advanceOutputGate` + `processMappedBuffers` + transport together across callbacks.
**Test to add**: multi-callback harness — engage transport, set rate 0 (post-snap), feed loud
live input for > silenceHold, then assert the ring window contains the live input, not zeros;
and assert the buffer's live side is non-zero through a toLive fade.

## C2 — CRITICAL (decision required): a 30 s pause destroys an armed tape's entire history

**What the user does**: arms a 15-minute tape on Spotify to retro-record, pauses (or the
album ends), comes back a minute later and hits save — or just resumes playing.
**What happens**: the recording is gone; the tape restarts empty. Silent data loss on the
feature's flagship flow ("save what just happened" is most wanted right after it *stopped*).
**Why the code produces it**: `cleanupStaleTaps` (AudioEngine.swift:1944-1975) E20-pins only
an **engaged** (non-live) transport. A pinned-live-but-armed tape is not "engaged", so after
the 30 s grace the tap is invalidated and `tapeTransportManager.release()` frees the ring.
The ring is owned outside the tap *precisely* so it survives tap death; this path deletes it
anyway. E29's wording ("app left the list … ring freed on release") arguably authorizes the
code — but E29 was written about app **quit**; a paused-but-running app leaving the audible
list is a different event with the same code path. The spec conflict is the finding: either
(a) stale cleanup releases the *tap* but keeps the `AppTapeTransport` + ring (timeline
freezes, which E21 already accepts for callback-dead gaps; export still works; playback
resumes on re-attach), or (b) Erik explicitly accepts "any 30 s pause clears the tape" and the
UI copy must say so. (a) matches the architecture's stated intent. Note `ignoreApp` and true
process-quit should still free the ring.

**Test exists?** No — `releaseForgetsTheApp` proves release frees the ring, but nothing pins
the *decision* that stale-cleanup must (or must not) call release for an armed tape.
**Test to add**: after the ruling — engine-level test that a stale, armed, pinned-live app
retains (or drops, per ruling) its ring across the cleanup sweep.

## I1 — Important: playback of the past continues with no visible controls once the app goes quiet

An engaged transport E20-pins the *tap*, so the audio correctly keeps playing — but the row it
is controlled from does not survive: `InactiveAppRow` receives no tape model (teammate's open
question — **ruled: a correctness-of-control problem, not a cosmetic gap**), and an *unpinned*
app that goes silent leaves `displayableApps` entirely. Worst case: user rewinds an unpinned
app, the app goes quiet, the row vanishes — ghost audio plays the past with no LIVE button, no
stop, no scrub, no visible source; the only escape is the debug URL scheme. This is the exact
scenario E20 exists for ("rewind of something that just stopped"). Minimum fix: an engaged
transport forces its app into the displayed list (reuse the pinned-inactive presentation) with
at least LIVE reachable; full strip on InactiveAppRow can follow the mockup.
**Test exists?** No; this is list-composition logic (`displayableApps`) and is testable.

## I2 — Important: the E17 promotion overlap is slightly worse than the accepted bound — record it

T3 states (and the code confirms) there is NO lock in `TapeTransportRT`. During crossfade
promotion the old primary's in-flight callback and the promoted callback can both be inside
`writeAndRender`. Spec Q6 accepted "one possibly-blended buffer". Actual worst case, traced:
(1) sequential interleaving of the two `writeToRing` calls can advance `writeFrames` twice
with near-identical content — one duplicated ~10 ms span in the timeline; (2) both threads
run `renderTransport`: `_readAbsQ`/`_readRingQ` are updated as a non-atomic pair, so the
racing read-modify-writes can leave abs and ring **desynchronized by up to one buffer** — a
constant playback offset that persists until the next seek/LIVE/loop jump calls `setPrimary`
(which re-derives ring from abs) — plus possible fade-counter tearing for that callback.
No memory unsafety: both positions stay clamped in-range, `interpolatedSample` cannot read
out of bounds, and the conditional ± capacity wrap survives lost updates. Bounded, self-
healing, rare — acceptable, but the acceptance on record ("read side is clamped; one blended
buffer") understates it. Accept explicitly or add a promotion-side fence; do not ship it as
"one blended buffer" in the docs.
**Test exists?** Not testable deterministically offline; the acceptance note is the artifact.

## Nits

- **N1** The ring records the primary's crossfade **fade-out** on every device switch
  (`crossfadeMultiplier` is inside the recorded gain), and never the secondary's ramp-in — a
  ~50–100 ms dip baked into the tape per switch. Inherent to "post-fader", but Q6 never states
  it; add to the E-notes/UI copy or exclude crossfade from the recorded gain later.
- **N2** `silenceOutput` writes ring silence without the stereo gate, so a non-stereo tap's
  ring advances **only while muted** (records nothing otherwise). Harmless today (transport
  bypassed anyway); gate `writeSilence` behind the same eligibility for hygiene.
- **N3** `horizonGuardFrames` 4096 equals the largest common HAL buffer — sufficient for
  forward rates (proved: gap shrink per callback < N ≤ guard), but a **negative** rate can
  cross the guard in one callback (shrink up to 5N at −4×), producing one callback of
  held-sample output via the per-frame clamp before forced-1.0 engages. Bounded to one
  callback; consider guard ≥ 5× max callback if reverse-into-horizon is ever audible.
- **N4** Meter freezes at a stale tape peak when muted-while-engaged (`lastOutputPeak` stops
  updating; substitution still applies). Cosmetic.
- **N5** `tapeModel`'s `onExport` captures `config.ringMinutes` at model-build time (≤ 33 ms
  staleness at 30 Hz rebuild). Harmless.
- **N6** `scrub(toSecondsBehindLive: 0)` transiently unpins to 4 frames behind live until
  `endScrub` snaps back. Inaudible; noted so nobody "fixes" the snap threshold away.
- **N7** Two exports within the same second overwrite (filename has 1 s resolution and the
  mover deletes the existing destination). Trivial.

## Ruling on AppTapeTransportTests (committed without a mutation report)

**Not theater.** The suite's assertions are ordering- and identity-based and would fail
against the classic breakages: an early free flips `.grace(ringAlive:)` to false; a skipped
nil-publish fails `host.lastWasNil`; a stale-generation publish leaves `.published` in the
log; the export test genuinely proves the exporter's reference outlives `disable()` past the
grace. The weak-reference liveness technique is sound (the fake host deliberately does not
retain). Gaps, all minor: no test publishes to a **different** host arriving mid-allocation
(the E32 claim in `attach`'s comment); disable-clears-loop/brake and rate-reapply are covered
in `TapeTransportPanelModelTests` rather than here (coverage exists, location surprising).
Mutation verification remains owed by convention, but I would not block on this suite.

## T3 deviations — each attacked, each stands

1. **Caller's-buffer LIVE fade**: correct, and better than the spec's wording — the ring's
   live edge is only readable to writeFrames−4, so a ring-read live side cannot hand off
   bit-exactly; fading against the incoming buffer makes pin-completion literally a no-op.
   Ring still records pure live during the fade (write precedes render). Verified.
2. **Skip-free E18 guard zone**: verified skip-free for forward rates given invariant (d)
   (gap math above); the clamp-then-force alternative would skip (1−r)·N per callback. The
   fade-active window falls back to the per-frame clamp for ≤ 50 ms — bounded, fine. The test
   (`horizonCollision`) genuinely proves ordering, exact position deltas, and output
   continuity, and would catch a regression to clamp-then-force.
3. **Stop-fade below |rate| 0.05**: correct — a stopped Catmull-Rom head holds the DC of its
   last sample; without the fade every brake ends on a held DC offset. Gain is applied only
   to ring-side reads, never to the live side of a fade (checked: `toLive`'s live side is
   unattenuated). Right.
4. **Atomic jumps**: correct — consuming a command mid-fade would drop a half-faded side;
   coalescing to latest-generation gives scrubs back-to-back 20 ms hops. Verified the seqlock
   (publish: payload→barrier→generation; consume: generation→payload→re-check, skip on race,
   no consumed-generation update on skip — re-picked next callback). Sound.
5. **Loop-suppressed auto-pin**: correct — a loop bounds the position by construction; auto-
   pin inside a loop would eject the user from a loop they deliberately set.

## Verified CORRECT (checked, not assumed)

- **E16**: ring gains exactly N frames and the head advances once across mirrored buffers;
  first-eligible-buffer rule; live passthrough leaves mirrors untouched (they are identical by
  construction); `copyLastOutput` called only when `writeAndRender` returned true, same
  callback; chain E1 flags independent of transport flags; both nil-independently paths safe;
  non-stereo bypass matches EQ/chain policy. Covered by real tests (callback-scope suite).
- **E21**: both silent early returns (`_forceSilence`, `_isMuted`) route through
  `silenceOutput` → `writeSilence`; the stale-generation callback guard zeroes output without
  writing, which is correct (the real primary still writes that callback); callback-dead gaps
  compress time per spec. `writeSilence` moves neither read head nor fade state.
- **E15/E23 grace ordering on every ring-freeing path**: disable, rateChanged (via disable),
  resize (via disable+enable), release, ignoreApp, stale cleanup — all publish nil → utility-
  queue grace → drop last reference; the orphan-allocation path frees without grace, correctly
  (never published); export's strong capture defers the free past `disable()`. The generation
  guard discards stale allocations instead of publishing them.
- **E24 exporter**: `copyRingWindow`'s discipline mirrors the writer's (samples→barrier→index
  publish; re-check after copy catches a mid-copy lap); the 1 s margin gives the copy headroom;
  chunk revalidation + whole-file restart from the new oldest keeps the file contiguous (the
  "drop from the head" policy is implemented correctly — a mid-file chunk loss restarts rather
  than tearing); hidden-sibling partial + rename; single-flight; nothing on the RT thread;
  ring held strongly for the whole copy. Wrap-spanning export covered by test.
- **E19 meter half**: substitution only when non-pinned; one-callback lag documented and under
  the smoothing; secondary keeps live peak (accepted per Q6).
- **Fixed-point clock**: step = round(rate·2²⁴) exact at 1.0; dual accumulators keep sample
  addressing modulo-free with |step| ≤ 4·2²⁴ ≪ capQ; Q40.24 headroom (≈289 years); window
  clamps keep the cubic kernel (index−1 … index+2) inside written, un-overwritten frames;
  rate 0 handled by the stopped branch (position dragged at the horizon, silence out);
  generation counter wrap-safe (`&+` with equality checks).
- **Lifecycle wiring**: attach on both tap-creation paths + BT re-rate + all five
  switch/update paths via `renderLayersRateChanged`; same-rate re-attach republishes the same
  object (position/content survive — tested); E22 discards and re-arms pinned-live with the
  user's rate re-applied; `setTransport` uses the exact swap-grace idiom.
- **RT-safety sweep of all new RT-path code**: no allocation, no locks (deliberately none —
  see I2), no ObjC, no logging; memcpy/memset/vDSP/libm only; `diagnosticsSnapshot` is
  final-class static dispatch, stack-only. Command setters and UI polling stay off the RT
  thread; panel models are built post-render (timer/onAppear), mutations in closures — no
  mutation-during-render.
- **E18 restore semantics**: `targetRate` never overwritten; requested rate resumes after
  seek-forward (tested); `_atHorizon` clears correctly through fades and seeks.

**Bottom line**: C1 is a merge blocker (deterministic recording corruption introduced by the
E19 gate branch). C2 is a data-loss decision Erik must make before merge, with (a) as the
recommended ruling. I1 should land before the feature is used without the URL scheme. The
keystone RT module itself withstood the attack — every deviation it took was the right call.
