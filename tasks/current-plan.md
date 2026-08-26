# FineTune fork — Erik's adjusted version

**Fork**: github.com/droptheoars/FineTune (upstream: ronitsingh10/FineTune, GPL-3.0)
**Local**: ~/Code/Personal/FineTune
**Status**: Phase 1 WORKING (Erik-verified 2026-08-25: launch clean, RC-20 loads and colours
Spotify after the c1b331f entitlement fix). Branch origin/feat/au-plugin-hosting at c1b331f.
PR not opened yet — one-click link + body in tasks/PR-BODY.md. Full listening checklist
(tasks/MANUAL-TEST-CHECKLIST.md) only partially run; device-switch test (test 5) still
unheard by human ears. **Phase 2 spec is WRITTEN and awaiting Erik's review**:
tasks/specs/2026-08-25-phase2-tape-transport.md (Fable xhigh, 2026-08-25). No Phase 2 code
started. Next actions are Erik's: hear checklist tests 5+7, decide on opening the Phase 1 PR,
then the transport-UI decision mockup loop.

**Phase 1 launch findings (2026-08-25 evening)**
- Hardened Runtime library validation blocked ALL third-party AUs (badge showed 'Not installed').
  Fixed by `com.apple.security.cs.disable-library-validation` (c1b331f). Invisible to the test
  suite — the offline harness only loads Apple units, which are exempt. Two minutes of real
  launch found what 1005 tests could not.
- UI polish debt: a plugin that exists but cannot LOAD shows the same 'Not installed' badge as
  a genuinely missing one — sent Erik down the wrong path. Distinguish the two states.
- The 20:50 crash report was a test-host under the scratch build dir (XCTest waiter), from the
  deliberate mutation runs — not the app.
- Dev build lives on Erik's Dock as ~/Desktop/FineTune-AU.app. Settings are now schema v13;
  running released v1.9.0 again would silently drop chains (v12 backup in session scratchpad).

## License note
GPL-3.0. Private use: no obligations. Distributing builds to others: source must be public under GPL.

## Already exists upstream (no work needed)
- Device hiding: pencil (edit mode) → eye icon per device row. Can't hide current default device.

## Roadmap (approved)

### Phase 1 — AU plugin hosting (the spine) [WORKING — Erik-verified smoke test; full checklist pending]
Decisions (Erik, 2026-08-25): app chain REPLACES default (never stacks). UI lives in the
expanded app row next to the EQ panel. Build is for Erik only for now (Iris may test;
future public release open — keep GPL hygiene, no notarization pipeline yet).
Acceptance tests: RC-20 on Spotify (settings survive relaunch, window opens) ·
Cassette on browser audio · speed WITHOUT pitch (TimePitch) · speed WITH pitch
(Varispeed) · default chain on everything, survives device switch.
RULED (Fable): actual speed change (rate ≠ 1.0) moves to Phase 2 — no bounded interim
sounds right on a live stream. Phase 1 still hosts TimePitch/Varispeed (clean at 1.0,
bounded degradation + badge at other rates); Phase 2 ring spec MUST feed the AU chain
from the transport read head. Acceptance tests 3/4 adjusted accordingly.
Known limitation: chain is post-fader — volume moves can pump dynamics plugins.
Build order T1–T9 with tiers is in the spec (keystone RT module = Fable build,
RT integration = Opus, UI = Sonnet, final Fable adversarial review of the RT diff).
Per-app AU chains (AUv2 + AUv3, in-process) inserted in existing DSP pipeline:
volume → EQ → **AU chain** → AutoEQ → loudness → soft limiter (limiter stays last).
(Fable ruling 2026-08-25: chain sits BEFORE AutoEQ — creative effects get headphone-corrected,
and Phase 2's ring buffer then records pre-correction audio so replays adapt to the new device.)
- Add / remove / bypass / reorder plugins per app
- Default chain for apps without their own
- Real plugin windows (AU view controller in floating window)
- Persistence via AU fullState, keyed per app like EQ settings
- Surface plugin-reported latency in UI (lip-sync warning)
- Interleaved ↔ deinterleaved shim (FineTune chain is interleaved, AUs want deinterleaved)
- Speed-without-pitch available day one via Apple stock TimePitch AU in chain
- Crash risk: plugins run in-process (accepted; CrashGuard cleans up aggregates). Same deal as every DAW.
- Day-one payoff: RC-20 / Wavesfactory Cassette on any app = tape character without building it.

### Phase 2 — Ring buffer + tape transport [SPEC WRITTEN — awaiting Erik's review]
Spec: `tasks/specs/2026-08-25-phase2-tape-transport.md` (Fable xhigh, 2026-08-25).
Per-app ring buffer (opt-in, default off; 23/115/346 MB for 1/5/15 min at 48kHz) enabling:
- I1 Rewind live audio (OB-4 style) — scrub into the past, explicit LIVE return
- I2 Tape mode — varispeed read head (pitch follows speed); tape stop/brake
- I3 Retro-record — export last N minutes to WAV in ~/Music/FineTune
- I10 Loop grab — mark + loop a chunk, OP-1 style
- Transport UI — BLOCKED on Fable decision mockup with Erik (§5 of the spec has the brief)

Key rulings Erik must sign off:
- **Q7 gate**: checklist tests 5 (device switch) + 7 (regression) must be HEARD before the RT
  integration task (T5) merges. Non-RT tasks may start meanwhile. Sharpened from Erik's lean.
- **Branch (G)**: new `feat/tape-transport` off `feat/au-plugin-hosting`; open the Phase 1 PR
  first so it stays a reviewable unit.
- **E22**: a device switch that changes SAMPLE RATE (A2DP↔SCO) discards the tape and snaps to
  live. No resampling of hundreds of MB, no mixed-rate ring.
- **E18 horizon collision**: when playback falls off the end of the tape, effective rate snaps
  to 1.0 pinned at the oldest audio (audible pitch snap) rather than garbling or force-jumping
  to live. Requested rate restores when the user seeks forward.
- **Opt-in cost**: retro-record can only save what was already recording. No "save the last 5
  minutes" for an app whose tape was off.
- **E28**: the Speed group (TimePitch/Varispeed) is retired from the plugin picker in Phase 2 —
  the transport fulfils its promise. Existing persisted slots keep Phase 1 behaviour.
- **Clock**: Q40.24 fixed point (not Double, not Q32.32 — the latter overflows at 12.4h).
- **Zero added latency at live is structural**: pinned-live writes to the ring and returns
  without touching the buffer.
- Phase 1 debt **T1**: the 'Not installed' vs 'Couldn't load' badge split is in Phase 2 scope.
Build order T0-T10 with tiers and gates is in the spec. HEAR-IT-EARLY checkpoint hangs off T5
(rewind Spotify 10s via debug URL scheme, before T6/T7/T9 proceed).

### Phase 3 — Fun DSP + glue (independent items, any order)
- I4 Karaoke / vocal remover — mid/side center cancel (~40 lines)
- I6 Auto-leveler — per-app LUFS normalization (K-weighting code already in repo)
- I7 Radio dial — crossfade between apps like tuning stations, static between
- I8 Audio desktop — spatial placement per app via Apple spatial mixer AU (Erik wants this)
- I9 Freeze — infinite spectral sustain hold
- I11 Scenes — one-click whole-board states (Deep work / Call / Meditate). Meditate mode = a scene (slow + wash + reverb chain), not a separate feature.
- I12 Notification effects — reverb/distance on system pings. NEEDS SPIKE: confirm which process owns notification audio and that it's tappable.

### Parked / rejected
- iOS version: impossible (platform forbids cross-app audio). Bridge: Mac as AirPlay receiver → iPhone audio becomes an app row. Custom iOS app playing its own audio = separate product idea, parked.
- VST3 hosting: rejected, AU covers the plugin library.
- Out-of-process hosting: rejected (AUv3-only, excludes AUv2 plugins, IPC latency).
- True master-bus restructure: rejected for v1 (per-tap architecture has no mix point; revisit only if a master compressor becomes a real need).
- Built-in tape character emulation: rejected — RC-20/Cassette via AU chain do it better.
- Generative ambient synth (OB-4 meditate literal clone): rejected — different project.

## Phase 2 build log (session 2026-08-25, continued)

**Erik's UI decisions (2026-08-25, interview loop)**
- Transport strip ALWAYS VISIBLE on a tape-enabled app row (permanent +26pt height accepted).
- Scrub = drag the bar. No jog buttons.
- Stop = tape brake (ramp to halt), not instant silence.
- Loop grab = last 10 seconds, edges draggable after.
- Deliberate controls (enable, ring length, speed, keep-pitch, save) live in a third
  `Tape` segment of the EQ | Effects toggle.
- Deferred by default, one-line reversals: no menu-bar icon change while behind live;
  no UI for reverse play (RT supports it); E18 pitch-snap kept until heard.

**Task status**
- [x] T1 badge split (Sonnet) — 28f1ac4
- [x] T2 settings v14 (Sonnet) — bc88804, plus 9b803d7 removing the hand-maintained
      CodingKeys footgun (orchestrator-requested simplification)
- [x] T3 TapeTransportRT keystone (Fable) — 2ca7aea, 13 tests, 14 mutations verified
- [x] T4 AppTapeTransport + TapeTransportManager (Opus) — c94966f, 17 tests.
      Committed WITHOUT a report; orchestrator audited the disable ordering by hand and
      confirmed publish-nil -> grace -> free with an ordering test that asserts the ring is
      still alive when the grace runs. Mutation-verification NOT confirmed — routed to T10.
- [x] T5 RT integration (Opus) — de82d54. E16 twin flags, E17 primary-only, E19 meter+gate
      substitution, E21 writeSilence on mute/forceSilence, E20 engaged-counts-as-audible,
      debug URL scheme (`finetune://tape?app=...&enable|rewind|rate|live|export|status`).
- [x] T6 TapeExporter (Opus) — 3dfb9ff, WAV/Float32 to ~/Music/FineTune.
- [x] T8 transport UI (Sonnet) — b0fb2ae, 25 tests, 9 previews matching the mockup
- [x] T9 end-to-end wiring (Opus) — 294c8c3, plus the Phase 2 manual listening checklist
      (HEAR-IT-EARLY minimum marked inside it).
- [x] T10 Fable adversarial review of the RT diff — 660accc. 2 Critical, 2 Important, 7 nits.
      The keystone RT module withstood the attack; all five T3 deviations were attacked and STAND.
- [x] T11 review fixes (Opus) — 82aa6e8, 3c6b257, b2ebda8, d9f81dd
- [x] T12 global save-length setting (Sonnet) — 8201b56. Erik-requested mid-session.
- [x] T13 speed slider fix (Sonnet) — 44b985f. Erik-reported "jumpy and buggy" on first real use.
- [ ] T14 torn-copy flake investigation (Opus) — running

**T10 findings and their resolution**
- **C1 CRITICAL (fixed, 82aa6e8)**: the E19 gate substitution poisoned the RECORDING. A stopped
  or braked tape has output peak 0, so the output gate re-armed and zeroed the LIVE input at the
  gain stage BEFORE `writeAndRender` copied it to the ring: everything the app played while the
  tape was stopped was recorded as silence, and the gate could only reopen on a non-silent TAPE
  peak, so it stayed shut for the whole stopped span. Root insight: in the built architecture the
  gate no longer protects playback at all (the transport overwrites the buffer after the gain
  stage), so the substitution defended nothing and only damaged the tape. Gate now follows
  livePeak; the METER keeps the substitution. **This bug was introduced by the orchestrator's own
  T5 brief, which pushed E19b hard as a must-fix.** The spec's E19 ruling is wrong as written.
- **C2 CRITICAL (fixed, 3c6b257, Erik ruled)**: `cleanupStaleTaps` E20-pinned only ENGAGED
  transports, so an armed-but-live tape was released and its ring freed after ~30s of silence.
  Pause Spotify, come back, retro-record is empty: silent data loss on the flagship flow.
  Erik's ruling: an armed tape survives a pause; the ring frees only on quit, disarm, or ignore.
  Accepted cost: up to the ring size stays resident while an armed app sits paused.
- **I1 (fixed, 3c6b257)**: an engaged transport now forces its app to stay in the list, so LIVE
  and stop stay reachable. Previously an unpinned quiet app left the list entirely, leaving ghost
  audio playing the past with no control except the URL scheme.
- **I2 (documented, b2ebda8)**: the crossfade promotion race is worse than the accepted "one
  blended buffer" — concurrent `writeAndRender` can double-advance the write clock (one duplicated
  ~10ms span) and desync the read-position pair (constant offset until the next seek/LIVE
  re-derives it). No memory unsafety, bounded, self-healing. Recorded accurately in code.
- Nits fixed: stale ringMinutes in the export closure, second-resolution filenames overwriting
  each other. `AppTapeTransportTests` ruled NOT theater by the review, though its
  mutation-verification was never reported.

**First real use (Erik, 2026-08-26 morning)**
- Speed slider felt "jumpy and buggy". Root cause was NOT smoothing: the slider's position was
  read from a model rebuilt by the 30fps level-poll timer, so between ticks the thumb snapped back
  to a stale value and fought the drag; the ±0.05 detent at 1.0 also applied mid-drag. Fixed by
  local drag state (the standard SwiftUI fix for a polled-state-backed control) plus detent on
  release only, plus a wider track. The rate-command path was checked and cleared: rapid
  `setTargetRate` calls retune the target continuously with no ramp restart, so no audible stepping.
- Option-key fine adjust SKIPPED: `LiquidGlassSlider` wraps an AppKit slider that reads absolute
  cursor position, so a precision mode needs that shared component restructured. Not worth the
  regression risk for one control. If finer control is still wanted, narrow the RANGE (0.25-2.0
  is a lot for the width) rather than chasing the gesture.

**Open flake under investigation (T14)**
`TapeWindowReaderTests/acceptedCopiesAreNeverTorn` failed once in a full-suite run, passed in
isolation and on rerun. NOT being accepted as flakiness: that test guards the exporter's lock-free
read against the RT writer, and load is exactly what widens a real race window. If real, a user's
saved file could contain a torn span silently.

## Phase 2 open decisions for Erik

**Orchestrator-verified gate (not self-reported)**: full suite on the integrated tree at
294c8c3 — exit 0, 1138 test cases passed, 0 failed.

**Known gap, deliberately not built**: `InactiveAppRow` gets no tape model, so a pinned but
silent app shows no transport strip. Rationale: with no tap there is no ring and the strip
would be showing a dead transport. Arming still persists per app from the active row. T10
was asked to rule whether this is a correctness problem or only a UI gap.

**Process finding**: four of six builder agents committed without reporting despite explicit
briefs. Mitigation used: orchestrator audits the commit by reading the code and runs its own
authoritative gate rather than trusting a silent commit. Worth tightening the builder brief
next phase — a commit without a report should be treated as unverified by default.
- Mockup + buildable UI spec: 8dc1675

**T3 deviations from spec, accepted (T10 must scrutinize)**
- LIVE-side crossfade uses the CALLER'S buffer, not a ring read. Spec §2.3 said both sides
  read from the ring, but the ring's live edge is only readable to writeFrames-4 (E26), so a
  ring-read live side pins with a 4-frame waveform jump (a click on every return to live).
  Fading against the incoming buffer makes the hand-off bit-exact. Spec wording is wrong here.
- E18 is SKIP-FREE by construction (guard zone forces effective rate 1.0 within
  horizonGuardFrames of the trailing edge) rather than clamp-then-force, which would skip
  (1-r)*N frames per callback — the jump-cut signature the spec bans.
- Stop-fade added: output gain ramps to zero below |rate| < 0.05, because a stopped
  interpolator holds the DC value of its last sample. Not in the spec; audible if omitted.
- Jumps are atomic (a pending command waits for the active fade), so scrub streams coalesce
  into back-to-back 20ms hops instead of clicking mid-fade.
- Auto-pin-to-live at r>1 is suppressed while a loop is active.

**T3 invariants a later task could unknowingly break**
(a) `writeAndRender` at most once per HAL callback, primary role only (no internal lock).
(b) `copyLastOutput` only when `writeAndRender` returned true, same callback.
(c) Command setters are single-publisher (MainActor); a second publisher breaks the seqlock.
(d) `horizonGuardFrames` must exceed the largest HAL callback or E18 stops being skip-free.
(e) T5 must route mute/`_forceSilence` through `writeSilence` or the timeline tears (E21).

**Environment finding (2026-08-25 evening)**
Disk hit 100% (341 MB free of 460 GB) mid-build; ~16 GB of it is Claude session
derived-data scratch under /private/tmp/claude-501. Both the agent and the orchestrator are
denied `rm`, so cleanup needs Erik. Mitigation in use: agents share one derived-data dir
(dd-t8) for incremental builds, and mutation-verification runs in a tiny isolated SwiftPM
package in the scratchpad instead of a full repo clone (T3's adaptation, ~seconds per run).

**Test-count convention**: report `totalTestCount` from `xcrun xcresulttool get test-results
summary`, not eyeballed streamed output. The tree had 854 @Test methods at T3; an earlier
"1034" was an invocation-style count and caused a false alarm.

## Phase 2 open decisions for Erik
- D3: SUPERSEDED. Erik chose to build Phase 2 before hearing tests 5+7; the Q7 merge gate was
  overridden by his explicit instruction. Tests 5 and 7 are STILL UNHEARD and now sit under a
  full phase of new RT work on the same code paths.
- D4: Open the Phase 1 PR (body in tasks/PR-BODY.md, SHA needs refresh). Still open.
- D5: E22 accepted implicitly (built as specced: a rate-changing device switch clears the tape).
- D6: DONE. Mockup loop ran 2026-08-25; Erik's four decisions are recorded above.
- D7: **Nothing in Phase 2 has been heard yet.** 935 test methods green, zero seconds of listening.
  The HEAR-IT-EARLY minimum (arm, rewind 10s, LIVE back) is in MANUAL-TEST-CHECKLIST.md.

## Model ladder for this project
- Spec/architecture: Fable xhigh (RT callback + third-party code in-process = silent-wrong territory)
- RT audio lane (ProcessTapController changes, AU render integration): Opus builders
- UI from approved mockup: Sonnet builders
- Reviewer ≥ builder; Fable adversarial review on the RT diff before merge.

## Session log
- 2026-08-25: Forked, cloned, remotes wired (origin=droptheoars, upstream=ronitsingh10). Xcode 26.6 + dev signing identity confirmed present. Brainstorm → roadmap approved. Phase 1 spec dispatched to Fable.

---

## Phase 1 build log (session 2026-08-25)

**Environment findings (T0 baseline)**
- Upstream project ships empty `DEVELOPMENT_TEAM` + manual Developer ID signing → plain
  `xcodebuild build` fails locally. Gate is now `scripts/dev-test.sh [build|test]`
  (adds Apple Development signing, team R6GT8Z86AD, `DERIVED_DATA` override for parallel agents).
- `FineTuneUITests` target is an empty stub that cannot load (pre-existing upstream defect,
  no source directory). Gate runs `-only-testing:FineTuneTests`.
- T0 baseline: build SUCCEEDED, FineTuneTests SUCCEEDED. Clean start confirmed.
- Xcode uses file-system-synchronized groups → new .swift files need no pbxproj edits.
- Acceptance plugins confirmed installed: RC-20 Retro Color (AUv2), Cassette (AUv2, present in
  BOTH /Library and ~/Library → picker must dedupe by component triple).
- **Settings-file collision**: dev build shares bundle ID + settings.json with installed v1.9.0.
  Running 1.9.0 after a v13 save re-writes the file as v12 and drops AU chains.
  Live v12 settings backed up to the session scratchpad before any build ran.

**Task status**
- [x] T0 baseline
- [x] T1 models + persistence (Sonnet) — 62c872a, 12 tests green, gate verified from main thread
- [x] T2 AUChainRenderState (Fable) — 00661ef, 11 RT tests green incl. real AUDelay + AUNewTimePitch@1.0
- [ ] T3 AppAUChain + AUChainManager (Opus) — running
- [ ] T4 RT integration (Opus) — running
- [x] T5 effects panel UI (Sonnet) — 940c8be
- [x] T6 plugin picker (Sonnet) — 940c8be, curated group applied
- [x] T7 plugin window controller (Opus) — 1f94839
- [x] T8 end-to-end wiring (Opus) — 0d48abe
- [x] T9 Fable adversarial review — DONE. 1 Critical, 2 Important, 6 nits.

**T9 review outcome (2026-08-25)**
- **F1 CRITICAL (merge blocker, being fixed)**: `rebuildInstances` deallocates all units up
  front but `rateChanged` leaves every slot `.ready`, and `rebuildRenderState` has no
  generation guard — so the first slot to finish re-allocating publishes a render state
  still containing the OTHER slots' deallocated render blocks. Deterministic on any device
  switch / A2DP-SCO transition with 2+ plugins. Effects: whole chain goes SILENT (not dry)
  for the re-alloc duration; nanStrikes accrue ~94/sec so a healthy slot gets spuriously
  auto-bypassed past ~1.1s; and `allocateRenderResources` runs concurrently with RT render
  inside third-party code — the exact UAF class E15 exists to prevent.
  **Zero test coverage of rateChanged/rebuildInstances existed** — this passed 3 green runs.
- **F2 Important**: NodeRTBox protects 28 bytes of counters against a retained-pull-block
  scenario while leaving the 64KB of scratch the same scenario would touch unprotected.
  Either the hedge is unnecessary or it is insufficient; the inconsistency is the finding.
- **F3 Important**: E1 once-per-callback logic untested despite ProcessingPipelineTests
  already having a multi-buffer harness. Green suite proving less than it appears to.
- Confirmed-correct: E1 logic itself, E15 on all direct paths (tests genuinely prove it via
  timestamped ordering, not theater), promotion gate + one-buffer tear bound, pull-block
  ping-pong aliasing, RT-safety sweep clean, KVC+unsafeBitCast sound on current ABI.
- Nits N1-N6 recorded in the review; N2 (unbounded pendingTasks) and N4 (nil rate read skips
  the stale guard) routed to T3 with the F1 fix.

**Findings during build (carry into T9's review packet)**
- F1: Swift's bridged `au.renderBlock` allocates 1 malloc per render (measured vs real AUDelay).
  T2 extracts the raw block once at build time via KVC + unsafeBitCast. Load-bearing;
  nobody may "simplify" it back. T9 must scrutinize the bitcast.
- F2: `au.inputBusses[0].isEnabled = true` is REQUIRED before allocateRenderResources or every
  render returns -10876 and the chain silently passes no audio while reporting ready.
  Spec §2.5 patched (46326f6).
- F3: `render()` false ⇒ caller's buffer bit-for-bit untouched (two entry guards only, no partial
  state). T4's mirror rule depends on this.
- F4: unlicensed plugins (soothe3/iLok) throw MODAL alerts at instantiation, not enumeration.
  Picker is safe to browse; adding such a plugin is the hazard. `auval -a` instantiates
  everything — never run it on this machine.

**Open decisions for T8**
- D2: InactiveAppRow (pinned but silent apps) has no EQ|Effects toggle — T5 left it alone since
  spec §5.1 names AppRow only. Decide whether pinned-inactive apps get an Effects tab.

**Decisions taken during build**
- D1: `ModeToggle` is hard-bound to `DeviceSelectionMode`. T5 may generalize it ONLY if no
  existing call site changes; otherwise a local segmented control in the new panel file,
  visually identical. Spec §5.1's intent is visual consistency, not literal reuse.

**All review findings closed (94565b5)**
- F1 Critical fixed + `AppAUChainRateRebuildTests/rebuildNeverPublishesDeallocatedUnits` (was red
  against the unfixed code, green after).
- F3 closed by 5 `AUChainCallbackScopeTests` covering every E1 once-per-callback case.
- F2 resolved. O1/O2 design hole closed: `Remove All Effects` on a default-following app now forks
  to an explicitly-empty chain instead of wiping the shared default, and `Save as Default Chain`
  makes the default buildable from the UI (new copy, Erik-authorized).

**Also fixed en route**: `HUDWindowControllerTimerTests` was non-hermetic upstream — it bailed
whenever the developer had a fullscreen app in front. Made the check injectable (1aaa413).

**Phase 2 seam is intact**: `render(interleavedStereo:frameCount:)` reads nothing from tap state,
and the insert point (post-EQ, pre-AutoEQ) is exactly where the ring write and transport read split.

---

## Session log addendum (2026-08-25, Phase 2 spec session)
- Fable xhigh architecture pass produced the Phase 2 spec. No code written, no branch cut.
- Findings while diagnosing Erik's popup during the session:
  - `settings.json` still reads `version: 12` even though the code defaults to 13 — the field is
    decoded from disk and re-encoded unchanged, so schema bumps never land in the file. Cosmetic
    today (AU chain data writes fine) but it keeps the downgrade hazard live. Fold a forced
    `version = 14` write into Phase 2's T2.
  - Erik reported the Effects panel missing while Spotify was playing but the popup showed
    'No apps playing audio'. Not diagnosed — he dropped it. If it recurs, suspect the process
    monitor / audio-recording permission for the dev build identity, not the AU chain layer.
