# Phase 2 — Ring Buffer + Tape Transport Spec

**Date**: 2026-08-25 · **Author**: Fable (architecture pass) · **Status**: Awaiting Erik's review
**Scope**: Per-app ring buffer + tape transport: I1 rewind, I2 tape mode (varispeed, stop/brake, speed-without-pitch), I3 retro-record, I10 loop grab. One transport mechanism serves all four.
**Branch ruling (§3-G)**: new branch `feat/tape-transport` from `feat/au-plugin-hosting`; open the Phase 1 PR first.

## 0. The locked seam (Phase 1 spec §F, quoted verbatim — this spec builds to it)

> The seam is the `AUChainRenderState.render(interleavedStereo:frameCount:)` boundary plus the insert point. Invariants Phase 1 must keep so Phase 2 never reopens it:
> 1. `render` takes an explicit buffer + frame count and reads **nothing** from tap state — no assumption its input is the live tap signal.
> 2. The insert point (post-EQ, pre-AutoEQ) is exactly where the ring buffer's write (tap side) and the transport's read (chain side) will split the pipeline: tap writes post-EQ audio to the ring; the transport produces N device-rate frames per callback (consuming ring content at rate r); the chain renders those N frames; AutoEQ/loudness/limiter continue live. The chain call itself does not move.
> 3. Rate-mismatch bookkeeping (§D) stays: in Phase 2 the transport, not the AU, owns the rate, and the counters become a transport-health diagnostic.

Verified intact in the built code: the chain call sits at ProcessTapController.swift:1498 between the EQ block (:1492) and AutoEQ (:1510), and `render()` touches nothing outside its arguments. The transport slots into that exact gap. The chain never learns the transport exists — it always receives N device-rate frames.

---

## 1. Goals / Non-goals

### Goals
- Per-app circular ring recording the post-fader, post-EQ signal (the exact chain-input signal today), opt-in, off by default.
- A tape transport reading from the ring: live passthrough with **zero added latency**, rewind/scrub, variable-rate play with pitch following speed (varispeed), tape stop/brake, loop region, explicit LIVE return, retro-record export to WAV.
- Speed-without-pitch via a transport-owned AUNewTimePitch (deferrable task, §8-T7).
- Ring and transport survive tap churn (device switch, health recreate, sleep/wake) exactly as AU instances do.
- Offline-testable: the whole RT transport renders against a synthetic ring with no live device.

### Non-goals (Phase 2)
- No transport UI in this phase's build decomposition — novel surface, Fable decision mockup with Erik first (§5). RT/lifecycle layers land behind a debug trigger.
- No persistence of transport *runtime* state (position, rate, loop). Quit = tape gone. Config only (§4).
- No multi-app / master transport (per-app only), no reverse-loop ping-pong, no export of the *processed* (chain/AutoEQ) signal (§6-E25), no resampling of ring history across a device-rate change (§3-Q6).
- Non-stereo taps: transport bypasses under the same `eqCanProcessStereoInterleaved` gate as EQ and the chain, one-time log. Same policy, same reason.

---

## 2. Architecture

### 2.1 Units and boundaries

```
Models/TapeTransportConfig.swift        Codable per-app config                     [new]
Audio/Transport/TapeTransportRT.swift   RT-facing ring + read head + clock         [new]
Audio/Transport/AppTapeTransport.swift  @MainActor per-app owner + lifecycle       [new]
Audio/Transport/TapeTransportManager.swift  Registry, attach, settings bridge      [new]
Audio/Transport/TapeExporter.swift      Retro-record WAV export (utility queue)    [new]
Audio/Engine/ProcessTapController.swift +setTransport(_:), callback insert         [edit]
Audio/Engine/AudioEngine.swift          Attach on tap create, rate change, idle pin [edit]
Settings/SettingsManager.swift          Settings v14: appTapeTransport             [edit]
```

Ownership mirrors the AU chain layer deliberately: `AudioEngine` owns `TapeTransportManager`; the manager owns one `AppTapeTransport` per enabled app; `AppTapeTransport` owns the `TapeTransportRT` object — **not the tap**. The tap holds only a `nonisolated(unsafe)` published pointer. Taps are disposable; the ring (up to ~346 MB of a user's listening history) is not.

The transport is **independent of the AU chain layer**: a separate published pointer, a separate manager, a new one-method protocol on the tap. An app with a ring and no chain works; an app with a chain and no ring works. `AUChainManager` grows zero transport concerns. Rejected: folding the transport into `AUChainManager` — the chain layer's contract is "immutable render plans", the transport's is "long-lived mutable RT state"; merging them blurs the one distinction that kept Phase 1 safe.

**`LoudnessDetector` reuse — ruled: not reusable.** Its ring (LoudnessDetector.swift:17) stores mono *squared* samples over a ~400 ms analysis window with a hop counter — an RMS estimator, not an audio store. No read head, no interleaved audio, wrong scale by six orders of magnitude. Nothing to salvage beyond the wrap idiom, which is three lines. New code.

### 2.2 Threading model

Same three domains as Phase 1, with one new wrinkle: the transport has *legitimately mutable* RT state (read position, write index), unlike the chain's immutable plans. The split:

1. **MainActor** — enable/disable, resize, rate-change rebuild, export kickoff, command *issuing* (target rate, seek, loop, LIVE, pin). Commands are aligned single-word atomic stores onto the RT object (§2.5), not pointer swaps.
2. **Utility queue** — ring allocation + zero-fill (up to ~346 MB; doing this on MainActor stalls the popup — §6-E23), export copy-out, ring deallocation after grace.
3. **HAL I/O thread (RT)** — `writeAndRender(...)`, the only transport call. Single writer of the write index and read position (primary callback only, §2.4). No allocation, no locks, no ObjC, no logging — house rules.

**Pointer-swap vs atomic-field rule**: the published `TapeTransportRT` pointer swaps only on *lifecycle* events (enable, disable, resize, device-rate change) using the exact `setAUChain` idiom — store, `OSMemoryBarrier()`, defer-release old after 0.5 s (ProcessTapController.swift:307). *Control* changes (rate, seek, loop, pin) never swap the object — a mode change must not cost a 115 MB reallocation. They are commands (§2.5). This is the load-bearing difference from the chain layer; do not "unify" it.

### 2.3 TapeTransportRT — the RT contract

One final class per (app, sampleRate, capacity). Contents:

- **Ring**: one contiguous `UnsafeMutablePointer<Float>` of `capacityFrames × 2` interleaved stereo Float32 at device rate, allocated and zeroed off-main before publication. Capacity is exact (`minutes × 60 × rate`), not power-of-two padded — reads and writes are block copies with at most one wrap split per callback; no per-frame modulo on the write path. Memory: 23.04 MB/min at 48 kHz. Interleaved because the write is one memcpy from the post-EQ buffer and the live read is one memcpy back; the chain seam is interleaved (§F); deinterleaving buys nothing here.
- **Write clock**: `nonisolated(unsafe) var writeFrames: Int64` — monotonic frames written since creation. Discipline: memcpy samples into the ring first, `OSMemoryBarrier()`, then advance `writeFrames` — so a concurrent exporter or UI reader never sees an index covering unwritten audio. Ring index = `writeFrames % capacityFrames`, computed once per callback.
- **Read clock**: `nonisolated(unsafe) var readPosQ: Int64` — fractional read position in **Q40.24 fixed point** (24 fractional bits). Advanced by `step = Int64((rate × 16_777_216).rounded())` per output frame. Ruled over `Double` accumulation: fixed point is deterministic (property tests assert exact positions, not tolerances), r = 1.0 is `step = 2^24` — integer advance, bit-exact, zero drift against the write clock. Ruled over Q32.32: 32 integer bits overflow at 2^31 frames ≈ 12.4 hours at 48 kHz — an all-day app session breaks it; Q40.24 overflows after ~289 years and still gives rate resolution of 2^-24 (≈ 6×10⁻⁸ relative, five orders below audibility).
- **Smoothed rate**: RT-side one-pole ramp of the actual rate toward `targetRate` (time constant ~20 ms; brake/stop use a longer configured ramp, §2.5). All rate changes are clickless by construction; there is no "set rate" discontinuity.
- **Interpolation**: 4-point Catmull-Rom on the fractional position for r ≠ 1.0. Linear rejected: audible HF loss on slowdown, and cubic is ~10 extra flops per frame. At **pinned-live** the interpolator is bypassed entirely (§2.4) — the live path is not "resample at 1.0", it is "don't touch the buffer".
- **Valid window**: `[writeFrames − capacityFrames + marginFrames, writeFrames − 4]` where `marginFrames` = 1 s. The −4 keeps the cubic kernel's lookahead off unwritten frames (§6-E26). The 1 s margin is headroom against the writer for both the read head and the exporter.
- **Discontinuity primitive**: every jump (seek, LIVE, loop wrap) renders a short equal-power crossfade between the old and new read positions — both sides read from the ring, so this is two interpolated reads and a blend, RT-cheap, no extra memory. Durations pinned: seek/scrub 20 ms, LIVE 50 ms, loop boundary 10 ms. There is exactly one jump mechanism; the three features are three parameterizations of it.
- **Mirror store**: retained interleaved copy of the last transport output (16384-frame capacity, same as `AUChainRenderState.mirrorStore`) for E1 mirrored buffers (§6-E16).
- **Audible peak**: `nonisolated(unsafe) var lastOutputPeak: Float`, computed during the render copy loop — the callback substitutes it into VU/gate when non-live (§3-Q4).
- **Diagnostics**: clamp-event count, seek count, live/behind flag, current lag in frames — aligned fields polled from MainActor for the (future) UI, same pattern as `diagnosticsSnapshot()`.

```swift
final class TapeTransportRT: @unchecked Sendable {
    /// RT entry point, primary callback only, once per callback (E16).
    /// Writes `frameCount` frames of `buffer` into the ring, then — when not
    /// pinned to live — replaces `buffer` with transport output. Returns true
    /// when the buffer was replaced (non-live), false when passthrough (live).
    func writeAndRender(interleavedStereo buffer: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool
    /// E16 mirror primitive, same contract as AUChainRenderState.copyLastRenderOutput.
    func copyLastOutput(into: UnsafeMutablePointer<Float>, frameCount: Int)
    /// Muted / force-silence path: keep the timeline continuous (E21).
    func writeSilence(frameCount: Int)
}
```

`writeAndRender` flow: memcpy buffer → ring (≤ 2 regions) → barrier → advance `writeFrames` → if pinned-live: update peak from buffer, return false (buffer untouched — **this is the zero-latency proof: at live the transport adds one memcpy out and changes nothing in the signal path**) → else: smooth rate toward target, consume any pending command (§2.5), clamp read window, interpolate `frameCount` frames into the buffer (with crossfade if a jump is active), update peak + mirror store + `readPosQ`, return true.

No gate/trylock is needed on the hot path in steady state: the write index and read position have exactly one writer (the primary callback). The crossfade-promotion overlap (§3-Q6) is closed the same way as the chain's — see E17.

### 2.4 Pipeline insert point + once-per-callback

Order inside `processMappedBuffers` becomes:

```
gain (volume × boost × crossfade × output gate)
  → EQProcessor
  → [ring write + transport read]     ← new, this spec
  → AU plugin chain                    (unchanged, fed transport output)
  → AutoEQProcessor → LoudnessEqualizer → LoudnessCompensator → SoftLimiter
```

**E1 extension — ruled explicitly (E16)**: a stacked mirroring aggregate delivers one identical buffer per sub-device. The ring write must happen exactly once per callback (double-writing would put every sample in the tape twice — half-speed playback of doubled audio, silent-wrong) and the transport read exactly once (the read head must advance once per callback). Rule: `writeAndRender` runs on the FIRST eligible buffer; every later eligible buffer gets `copyLastOutput` **from the transport** when the transport rendered non-live, then the chain's own E1 memcpy applies on top as today. When the transport is live-passthrough, mirrored buffers are already correct by construction (identical input, identical gain/EQ) and need no copy. The `auChainDidRender` bookkeeping at ProcessTapController.swift:1372 gains a sibling `transportDidRun` flag; the two are independent because either can be nil.

**Primary-only (E17)**: the callback passes the transport pointer only in the primary role, exactly like `auChain` at :1666/1679. The secondary tap during a crossfade neither writes the ring (double-write) nor reads it (two concurrent read-head writers = data race). Consequence ruled in §3-Q6.

Transport runs under the same stereo gate as EQ and the chain. Oversized callbacks: no 4096 slice needed for the ring itself (capacity ≫ any callback; wrap split handles any N); the crossfade and interpolation loops are plain per-frame code with no fixed scratch beyond the mirror store.

### 2.5 The transport state model — one mechanism, four features

The RT truth is deliberately tiny — **four control values, not four features**:

| RT field | Type | Meaning |
|---|---|---|
| `pinnedToLive` | Bool (UInt8) | true = passthrough mode, read ≡ write |
| `targetRate` | Float bits (UInt32) | signed; r ∈ [−4, +4]; 0 = stopped |
| `loopStartFrames` / `loopEndFrames` | Int64 ×2 | loop region; loopEnd = 0 means no loop |
| seek command | Int64 pos + Int32 generation | jump-with-crossfade request |

MainActor issues commands as aligned atomic stores; the seek pair is published seqlock-style (position first, barrier, generation last; RT consumes on generation change — the `CrossfadeState` idiom). Coalescing: the RT thread consumes at most one seek per callback; the latest generation wins (E27).

The four features are projections of this model:
- **I1 Rewind**: `pinnedToLive = false` + seek(pos) + targetRate = 1.0. Scrub = repeated seeks.
- **I2 Tape mode**: targetRate = user speed (pitch follows — the interpolating read head IS varispeed). Tape stop/brake: targetRate = 0 with the brake ramp constant (pinned: stop 150 ms, brake 800 ms — mockup may retune, values live in one place). The recording head never stops (§3-Q4).
- **I10 Loop grab**: loop region + the 10 ms boundary crossfade. Loop bounds are clamped into the valid window each callback like the read head — a loop older than the ring degrades honestly by sliding forward (flagged in diagnostics).
- **I3 Retro-record**: not an RT feature at all — the exporter reads the same ring from the utility queue (§3-Q5).
- **LIVE**: one command: seek(write head) + `pinnedToLive = true`, through the 50 ms crossfade.

**Horizon collision — the silent-wrong case, ruled (E18)**: at r < 1.0 (or stopped) behind live, the write head gains on the read head. When the clamp binds (read head pushed by the window's trailing edge), naive clamping produces exactly the Phase 1 §D "chunky slow-motion with jump-cuts" — each callback skips the frames the window ate. Rule: when the clamp binds, the transport forces the *effective* rate to 1.0 while pinned at the horizon (clean, continuous, oldest-available audio — the tape has simply run out, which is also what an OB-4 does) and sets a diagnostic flag for the UI. `targetRate` is not overwritten; releasing the pressure (user seeks forward or hits LIVE) restores the requested rate. A stopped transport at the horizon holds silence output while its *position* is dragged forward by the window — resuming play resumes from valid audio. The audible consequence of collision is a pitch snap from r to 1.0 at the horizon; stated honestly, and it is the least-wrong option (garbled granular playback and forced-LIVE surprise jumps were the alternatives — the second violates Erik's no-surprise-jumps requirement directly).

**Speed-without-pitch (T7, deferrable)**: a transport-owned AUNewTimePitch, hosted through a **single-node `AUChainRenderState`** — reusing Phase 1's raw-block extraction, pull bookkeeping, input-bus enable, and E15 grace wholesale rather than building a second AU hosting path. Mechanics: when `preservePitch` is on and r ≠ 1.0, the transport reads ⌈r×N⌉ ring frames (integer stepping + fractional carry, no resampling) into staging, sets the node's per-cycle provided frames, and renders N output frames; TimePitch pulls ~r×N and time-stretches. The AU's rate parameter is set from MainActor via its parameter tree. The transport still owns the clock — the AU is a resampler in its employ, which is precisely what §F.3 "the transport owns the rate" means mechanically. **What the Speed group becomes**: retired from the picker in Phase 2 (its promise is fulfilled by the transport); existing persisted TimePitch/Varispeed slots keep Phase 1 behavior, and the §D badge copy updates to point users at the transport's speed control (E28). The §D pull-mismatch counters stay untouched and now unambiguously mean "this chain plugin is fighting the transport" — the promised transport-health diagnostic.

### 2.6 Lifecycle: AppTapeTransport + TapeTransportManager

`AppTapeTransport` (@MainActor, per app):
- **enable(rate:)**: allocate + zero on utility queue → publish to tap (pointer swap) → state `ready`. Generation-guarded like `AppAUChain.generation` — a disable or rate change during allocation discards the orphan allocation instead of publishing it.
- **disable()**: publish nil → utility-queue sleep(0.5 s grace, E15 idiom) → deallocate ring. The RT thread may be mid-`writeAndRender`; the grace outlives any callback.
- **rateChanged(to:)**: ruled in §3-Q6 — publish nil, discard, reallocate at the new rate, republish, transport comes back **pinned to live with an empty tape**.
- **attach(to:rate:)**: tap churn re-bind. Same rate → republish the same RT object (position, tape content, mode all survive — this is the point of outside ownership). Different rate → rateChanged path.
- **export(lastMinutes:)**: snapshot `writeFrames`, hand the ring pointer + window to `TapeExporter` on the utility queue (§3-Q5). The RT object is retained by the exporter for the copy duration; disable during export defers the free until the exporter finishes (simple refcount by ownership).

`TapeTransportManager`: registry keyed by `persistenceIdentifier`, created from Settings v14 on demand, attach called from the same two tap-creation paths as the chain (§2.6 of Phase 1, E14) plus `handleBTDeviceSampleRateChanged` (AudioEngine.swift:2049) alongside `auChainRateChanged`. Release on app-left-list frees the ring (E29).

The tap gains `func setTransport(_ rt: TapeTransportRT?)` (swap idiom, identical to `setAUChain`) behind a new one-method `TransportHosting` protocol.

**Idle-teardown pin (E20)**: AudioEngine tears down taps for apps that go silent/leave. An engaged (non-live) transport is *the user actively listening to the past* — the engine must treat `transport is engaged` as "audible" in its idle/health logic, or rewind playback dies mid-listen the moment the app goes quiet (which it often is, during a rewind of something that just stopped). App **quit** still ends playback (the tap and IOProc die with the process) — accepted; the ring is freed on release.

---

## 3. Rulings Q1–Q7 (+ G/H/I)

### Q1 Ring placement, format, ownership — ruled
Post-fader post-EQ write at the §F point (locked; the tape records what you hear, minus device correction — volume moves and mute are baked in, §3-Q4/E21). Interleaved stereo Float32 at device rate (§2.3 — one memcpy each way, matches the seam format). **Opt-in per app, default off** — Erik's lean confirmed: at 23 MB/min, always-on for every audible app (browsers, Slack) is hundreds of idle MB; and a feature this deliberate should be armed deliberately. The honest cost of opt-in, stated: retro-record can only save what the ring was already recording — there is no "save the last 5 minutes" for an app whose tape was off. That is inherent to opting in; the toggle copy must make it clear recording starts *now*. Ownership: `AppTapeTransport` allocates (off-main) and owns; the tap sees a published pointer only; taps are disposable, rings are not (§2.1, §2.6). Rate change: §Q6. RT write discipline: §2.3 (samples → barrier → index; once per callback E16; primary-only E17; silence-fill under mute E21).

### Q2 Catch-up policy — ruled
**No automatic return to live, ever.** Return happens only by explicit LIVE command (50 ms ring-internal crossfade, §2.5) or by the user fast-forwarding into the live edge — FF at r > 1 that reaches the window's leading edge auto-pins to live through the same crossfade, which is the natural "tape caught up" reading of a user-driven action, not a surprise jump. Rejected: auto-fast-forward after rewind (violates the OB-4 model — being behind is a *place you chose*, not an error state), and hard jumps (audible click; every discontinuity goes through the jump primitive). Falling behind the window — the write-catches-read collision — is E18, ruled in §2.5: pin at the horizon at effective rate 1.0, never garble, never force-LIVE.

### Q3 Clock ownership — ruled
The transport owns the clock, concretely: **read position in Q40.24 fixed point, advanced by a rounded fixed-point step per output frame, single-writer on the RT thread; the HAL's demand for N frames is always met exactly; the ring is consumed at rate r via Catmull-Rom interpolation** (§2.3 — including why not Double and why not Q32.32). Varispeed (pitch follows speed) is the interpolating read head itself — no AU involved. Speed-without-pitch is a transport-*owned* TimePitch fed from the read head at integer stepping (§2.5): the AU never owns the rate; it converts ⌈r×N⌉ transport-supplied frames to N. The user-chain Speed AUs are retired from the picker; the §D counters become the transport-health diagnostic (E28). §F.3 discharged.

### Q4 Non-live playback: meters, gate, loudness, limiter, the write — ruled
- **VU meter**: today it reads the live *input* (ProcessTapController.swift:1583-1598). During rewind that shows a dead meter while audio plays — looks broken. Rule: the meter shows what you hear. Non-live, `_peakLevel` is fed from `lastOutputPeak` (§2.3); at live, today's exact behavior is kept (zero regression surface).
- **Output gate — a real silent-wrong found in audit (E19)**: the gate advances on live input peak (:1613-1624). A rewind while the app is silent live would accumulate 200 ms of "silence", re-arm the gate, and **mute the transport playback**. Rule: when the transport is non-live, the gate's input peak is the transport's output peak. One branch at the gate call site.
- **LoudnessEqualizer / LoudnessCompensator / SoftLimiter**: all sit after the chain and process the audible buffer in place — they see transport output through the chain with no change whatsoever. Locked by §F and confirmed at :1515-1525.
- **The ring write never stops** while the transport is enabled and the tap alive — in every mode including tape-stop/brake. The record head and the play head are independent; a stop brakes only the play head, and hitting LIVE after a stop always lands on fresh audio. During user mute and `_forceSilence`, the write is **silence** to keep the timeline continuous (E21) — the mute early-return (:1630) and force-silence path call `writeSilence(frameCount:)`. Periods where the callback does not run at all (device dead, teardown windows) simply do not advance the tape — ring time is callback time, not wall time; a rewind across such a gap plays the two sides back to back. Stated, accepted.

### Q5 Memory / retention / export — ruled
Ring length: per-app choice of **1 / 5 / 15 minutes, default 5** (23 / 115 / 346 MB at 48 kHz; the UI shows the MB figure — copy pinned at mockup time). Wrap: continuous overwrite; the reachable past is `capacity − 1 s` (margin, §2.3). Resize = disable + enable (tape clears; stated in UI copy).
Retro-record export: **not on the RT thread** — `TapeExporter` on a utility queue copies the window in chunks, then writes **WAV, Float32, device rate** via `AVAudioFile` to `~/Music/FineTune/<App Name> <yyyy-MM-dd HH.mm.ss>.wav`, revealing in Finder on completion. Float32 WAV: bit-exact, universal, no encoder; our max file (~346 MB) is far under WAV's 4 GB ceiling. Writer race ruled (E24): the exporter snapshots `writeFrames` = W, copies oldest → W, and re-validates each chunk against the live (advancing) overwrite point; any chunk the writer has since overwritten is dropped from the *head* of the export — the file is always coherent, at worst a few seconds shorter at its oldest end, never torn. **What the file contains (E25)**: the post-fader post-EQ signal — no AU chain color, no AutoEQ, no loudness/limiter. Correction *should* be absent (it is device-specific); the chain's absence is audible and is stated in the export UI copy. Rendering exports through the live chain is rejected — the instances are stateful and busy (Phase 1 §C's no-duplication ruling applies with full force).

### Q6 Device switch mid-rewind — ruled
Same-rate switch (the common case): the ring and position survive untouched — the transport is owned outside the tap and re-attaches at promotion like the chain. **During the ~50 ms crossfade**: transport is primary-only (E17, same ruling and same reason as Phase 1 §C — a second concurrent RT reader/writer on the ring state is a data race inside our own code this time). Audible consequence, stated honestly: the incoming device contributes *live* audio to the 50 ms blend (during BT warmup it is muted anyway), and past-playback resumes at promotion with position intact. Rare, brief, bounded — same acceptance envelope as the chain's dry window. The promotion overlap race (old primary's in-flight callback vs the promoted one) is bounded to one buffer exactly as in Phase 1; worst case is one callback where both write the same ring region — identical mirrored content by construction, and the read side is clamped; no memory unsafety, one possibly-blended buffer. Accepted.
**Rate actually changes** (A2DP↔SCO, some switches): ruled — **discard the tape, reallocate at the new rate, come back pinned to live** (E22). The recorded frames are in old-rate time; the alternatives are resampling hundreds of MB in the background (heavy machinery for a rare event) or a mixed-rate ring with region metadata (complexity with silent-wrong written all over it). Erik hears: switching to a device at a different rate mid-rewind snaps to live and clears history; the UI must say the tape restarted (mockup item). The transport's `attach` compares rates and self-heals exactly like `AppAUChain.attach` (AppAUChain.swift:279-292).

### Q7 Phase 1 debt gating — ruled, not shrugged
1. **Checklist test 5 (device switch) and test 7 (regression) must be heard by Erik before Phase 2's RT-integration task (T5) merges.** Sharpened from Erik's lean: the transport edits the very paths F1-Critical lived in (`rateChanged`/rebuild/promotion), and stacking unverified RT changes on unheard RT changes compounds unknowns — the entitlement lesson says 1005 green tests cannot stand in for two minutes of ears. Non-RT tasks (T1–T4) may proceed meanwhile; the gate is on T5's merge, not on starting Phase 2.
2. **The "Not installed vs failed-to-load" badge split is in scope as T1** (it already cost a wrong diagnosis on launch night, and Phase 2's QA re-exercises plugin loading). `SlotState.failed(reason)` already distinguishes the cases (AppAUChain.swift:175-181); the fix is UI mapping + copy. Copy pinned: `.missing` → `Not installed` · other failures → `Couldn't load` with the reason in a tooltip.

### G. Branch — ruled
**New branch `feat/tape-transport`, from `feat/au-plugin-hosting`. Open the Phase 1 PR now** (body ready in tasks/PR-BODY.md, one commit behind — refresh the SHA). Reason: Phase 1 is a complete, ear-verified, reviewable unit; growing its branch through Phase 2 makes the PR unboundedly large and blocks the merge on months of transport work. Phase 2's PR stacks on Phase 1's (or targets main after it merges). Rejected: building on the same branch — the only argument for it is saving one `git switch -c`.

### H. Feature interaction — ruled
One transport, one state model (§2.5): four RT control values, one jump primitive, one clamp. I1/I2/I10 are projections; I3 never touches the RT thread. **Nothing is deferred out of Phase 2 at the feature level; T7 (speed-without-pitch) is the designated pressure-relief valve** — it is the only task with a second AU-hosting surface, it is cleanly severable (its absence just greys a toggle), and tape mode (pitch-follows-speed) already delivers the I2 core without it.

### I. Settings v14 — ruled
```swift
struct TapeTransportConfig: Codable, Equatable {
    var isEnabled: Bool = false
    var ringMinutes: Int = 5          // 1 | 5 | 15 (clamped on decode)
    var preservePitch: Bool = false   // T7; ignored until built
}
// Settings v14:
var appTapeTransport: [String: TapeTransportConfig] = [:]
```
version → 14, `decodeIfPresent` + default, house migration idiom exactly (SettingsManager.swift:152-199). Keyed by `persistenceIdentifier` like `appAUChains`. `ignoreApp`/`pruneStaleSettings`/`resetAllSettings` treat an *enabled* config as user intent (kept), mirroring the non-empty-chain rule (:393, :701). Runtime transport state is deliberately not persisted. The v13→v14 downgrade hazard note carries over verbatim from Phase 1 (an older build rewrites the file and drops the field — E30).

---

## 4. Latency at live — the proof, stated once
Pinned-live `writeAndRender` copies the buffer *out* to the ring and returns without touching the buffer (§2.3). The signal path is bit-identical to transport-disabled; added cost is one memcpy (~4 µs for 512 frames) and one index advance. Zero added latency at rate 1.0 live is therefore structural, not measured — and T3's harness asserts bit-exactness anyway.

## 5. UI — decision mockup pending (NOT a build task)

The transport surface is a novel interaction model; per the design lane it gets a Fable decision mockup in an interview loop with Erik before any UI task is cut. **The mockup session must decide:**
- **Where the transport lives**: in the expanded app row (third mode next to `EQ | Effects`? a strip under the row?) and what the collapsed row shows when a transport is engaged (the user must never wonder why an app is playing "wrong" audio — a non-live indicator on the unexpanded row is mandatory; its form is the mockup's call).
- **The state → affordance map**, one visual per state: off · recording-live · behind-live playing · tape-speed (r ≠ 1) · stopped/braked · looping · pinned-at-horizon ("end of tape", E18) · tape-cleared-after-rate-change (E22).
- **Affordance list to place**: enable toggle (+ ring length with MB shown) · scrub/seek gesture · LIVE button (the one Erik asked for) · speed control + brake/stop · loop set/clear · retro-record save · preserve-pitch toggle (T7).
- **Copy to pin** (builders paste, never write): the enable-toggle explainer ("recording starts now", memory figure) · end-of-tape state · tape-cleared notice · export success/location · export content caveat (E25: "saved without effects or headphone correction") · the retired Speed-group badge text (E28).
- **Questions Erik answers in the loop**: scrub gesture model (drag a bar vs jog behind-time buttons)? Is stopped-tape silence or brake-to-silence the default stop? Loop grab UX (mark in/out live, or grab-last-X)? Does engaging rewind deserve a global visual cue (menu-bar icon change)?
- **Interim**: until the mockup lands, T5 exposes debug-only controls via the existing URL-scheme surface (guide/) — enable/seek/rate/live/export — which is also the HEAR-IT-EARLY vehicle (§8).

## 6. Edge-case audit (E-codes continue Phase 1's numbering)

- **E16 Once-per-callback, ring + transport** — E1 extended: ring write and read-head advance exactly once per HAL callback, first eligible buffer; later mirrored buffers get `copyLastOutput` when non-live, nothing when live (already identical); chain E1 logic unchanged on top. Double-write = doubled tape (silent-wrong); double-read = 2× advance. RT-review must-verify.
- **E17 Primary-only transport** — secondary tap neither writes nor reads during crossfade (§C's reasoning, now against our own data race). Promotion overlap bounded to one blended buffer; accepted.
- **E18 Horizon collision** — clamp binds → effective rate 1.0 pinned at oldest audio + flag; requested rate restored when pressure lifts. Never garble, never auto-LIVE.
- **E19 Gate/VU fed by dead live input during rewind** — gate would re-arm and mute playback; meter would flatline. Both substitute transport output peak when non-live.
- **E20 Idle-tap teardown mid-rewind** — engaged transport counts as audible in engine idle/health logic; otherwise playback dies when the app goes quiet, which is precisely when rewind is used.
- **E21 Timeline continuity under mute/forceSilence** — write silence, never skip; callback-dead gaps compress time (accepted, stated).
- **E22 Rate change discards tape** — snap to live, empty ring, UI notice. No resampling, no mixed-rate ring.
- **E23 Allocation off-main** — up to 346 MB alloc+zero on the utility queue, generation-guarded publish; disable frees only after the 0.5 s grace (E15 idiom) and after any in-flight export completes.
- **E24 Export races the writer** — snapshot + per-chunk revalidation; overwritten chunks drop from the file's head; never torn, never blocking RT.
- **E25 Export is post-EQ pre-chain** — no AU color, no AutoEQ/loudness/limiter. Stated in UI copy; offline chain rendering rejected.
- **E26 Cubic lookahead at the live edge** — free-mode window upper bound is `writeFrames − 4`; pinned-live bypasses interpolation entirely.
- **E27 Seek coalescing** — one seek consumed per callback, latest generation wins; scrubbing is a stream of coalesced seeks, each through the 20 ms crossfade.
- **E28 Legacy Speed AUs in chains** — picker group retired; existing slots keep §D badge behavior with updated copy pointing at the transport. Pull-mismatch counters = transport-health diagnostic (§F.3).
- **E29 App quits mid-playback / before export** — tap dies with the process; playback ends; ring freed on release. Retro-record must be triggered while the app row is alive. Accepted, documented.
- **E30 Settings downgrade** — v14 field dropped by any older build that rewrites settings.json; same hazard and same backup advice as Phase 1's v13 note.
- **E31 Ring wrap correctness** — writes and reads split at the physical wrap (≤ 2 regions); the Q40.24 position never wraps in practice (2^39 frames ≈ 289 years); property tests cover reads spanning the wrap seam and the exporter's wrap math.
- **E32 Enable-while-crossfading / attach ordering** — publish goes through the same attach path as the chain on every tap-creation route (E14 equivalent); a transport enabled mid-switch attaches to the primary and is simply absent from the dying secondary.

## 7. Acceptance tests

Offline (deterministic, no live audio — the T3/T5 gates):
1. **Live passthrough bit-exact**: known signal through `writeAndRender` pinned-live; output buffer bit-identical to input; ring contains the signal.
2. **Rewind exactness**: write a frame-indexed ramp; seek back k frames at r = 1.0; output equals the ramp delayed by exactly k — fixed-point position asserted *equal*, not approximate.
3. **Clock property tests**: for random r and callback counts, `readPosQ` equals `k·N·step(r)` exactly; r = 1.0 advance is integer; long-run drift is zero by construction; wrap-seam reads correct (E31).
4. **Horizon collision event log**: slow playback into the clamp; assert ordering — clamp event precedes any effective-rate change, requested rate restored after seek-forward, output never contains the §D jump-cut signature (frame-index discontinuities), per the prove-ordering-not-timing convention.
5. **Jump primitive**: seek/LIVE/loop produce an equal-power blend of the two positions over exactly the pinned durations; loop wraps at the boundary with the 10 ms blend.
6. **E16**: two mirrored buffers per callback → ring gains N frames (not 2N), read head advances once, second buffer equals the first.
7. **Mute timeline (E21)**: write-silence keeps `writeFrames` advancing; a rewind across the muted span plays silence of the right length.
8. **Export under fire (E24)**: continuous writing during export; file decodes, content matches the reference for all non-overwritten frames, dropped head bounded by write speed × export duration.
9. **Memory bounded and measured**: allocation is exactly `capacityFrames × 2 × 4` bytes + O(1) fixed state, asserted; enable/disable cycles leak nothing (instrumented count).
10. **T7 (if built)**: TimePitch path at r = 0.5 preserves pitch (zero-crossing rate of a sine within tolerance) while duration doubles; pull bookkeeping shows no sustained mismatch.
11. **Full existing suite (1005 tests) green** throughout.

Manual (Erik's ears, checklist authored in T9, MANUAL-TEST-CHECKLIST.md format): rewind Spotify 30 s and listen · tape-stop and brake feel · 0.5× music slowdown (pitch drops) · LIVE return click-free · loop a chorus · retro-record export opens and plays in QuickTime · device switch mid-rewind (both same-rate and BT rate-change, expecting E22's clear) · A2DP↔SCO call with transport engaged · full Phase 1 regression with transport enabled-but-live (must be indistinguishable from disabled).

**HEAR-IT-EARLY checkpoint — hangs off T5's gate**: the first audible milestone is "rewind live Spotify 10 s via the debug URL scheme and hear the past, then LIVE back" — run by Erik the day T5 lands, before T6/T7/T9 proceed. Phase 1's entitlement lesson is the reason this is a scheduled gate and not a courtesy: two real bugs escaped 1005 tests and were found in minutes of listening.

## 8. Build decomposition

Order is dependency order. Reviewer ≥ builder; deterministic gates before any model review; one Fable adversarial review of the combined RT diff (T3+T5) before merge. T0 is the Phase 1 closeout gate ruled in §3-Q7.

**T0 — Phase 1 closeout** · `Run this on: n/a — Erik's ears + one-command ops`
Erik runs checklist tests 5 and 7; open the Phase 1 PR (tasks/PR-BODY.md, refresh SHA); cut `feat/tape-transport`. Gate: tests 5+7 logged heard-green; PR URL exists.

**T1 — Badge split debt** · `Run this on: Sonnet · medium — pinned copy, existing SlotState already distinguishes the cases`
Files: Effects panel badge mapping + copy (§3-Q7.2). Gate: unit test mapping every `FailureReason` to its copy; build green; walkthrough with a renamed .component.

**T2 — Settings v14 + TapeTransportConfig** · `Run this on: Sonnet · medium — fully pre-decided Codable work, house idiom`
Files: `Models/TapeTransportConfig.swift` (new), `SettingsManager.swift`, config tests. Pre-decided: §3-I verbatim, clamp on decode, prune/ignore/reset integration. Gate: round-trip + v13-payload decode + prune-keeps-enabled tests green.

**T3 — TapeTransportRT (RT keystone)** · `Run this on: Fable · xhigh — the one keystone module: fixed-point clock, window clamp, jump primitive, E16 mirror become everyone's invariants; every failure mode is silent-wrong`
Files: `Audio/Transport/TapeTransportRT.swift` (new), `TapeTransportRTTests` (new). Pre-decided: §2.3/§2.5 contracts, Q40.24, Catmull-Rom, command atomics, clamp/E18, crossfade durations. Judgment: exact interpolation/crossfade mechanics, command consumption ordering. Gate: acceptance tests 1–7 + 9 green offline; mutation-verified per house convention.

**T4 — AppTapeTransport + TapeTransportManager** · `Run this on: Opus · high — correctness-critical async lifecycle: generation guards, off-main alloc, grace-fenced free, export refcount`
Files: both managers (new), lifecycle tests with injectable allocation/grace. Pre-decided: §2.6, E22/E23/E29/E32. Gate: event-log ordering tests (publish-nil precedes free; free waits grace; stale generation discards; attach same-rate preserves position).

**T5 — RT integration: ProcessTapController + AudioEngine** · `Run this on: Opus · high — the RT lane; MERGE-GATED on T0; then Fable adversarial review of the T3+T5 diff`
Files: `ProcessTapController.swift`, `AudioEngine.swift`. Pre-decided: insert point §2.4, E16 flag pairing, E17 primary-only, E19 gate/VU substitution, E20 idle pin, E21 silence writes, attach points, debug URL-scheme controls (§5). Judgment: minimal-diff placement. Gate: full suite green + E16 callback-scope tests (extend `AUChainCallbackScopeTests` harness) + **HEAR-IT-EARLY**: Erik hears rewind + LIVE via the debug scheme.

**T6 — TapeExporter (retro-record)** · `Run this on: Opus · high — lock-free reader racing the RT writer + file IO; data-loss-adjacent`
Files: `Audio/Transport/TapeExporter.swift` (new), export tests. Pre-decided: §3-Q5, E24 revalidation, destination/naming. Gate: acceptance test 8 + a real exported file plays in QuickTime (logged).

**T7 — Speed-without-pitch (deferrable)** · `Run this on: Opus · high — reuses Phase 1's single-node AU hosting; integration-subtle pull bookkeeping, not novel architecture`
Files: transport-side TimePitch node wiring. Pre-decided: §2.5 mechanics, E28 picker retirement + badge copy. Gate: acceptance test 10 with real AUNewTimePitch offline. Skippable without touching any other task if Phase 2 needs to land.

**T8 — Transport UI** · **BLOCKED — no build task exists until the §5 Fable decision mockup with Erik.** When it lands, visual implementation goes to Sonnet per the design lane ("match the artifact, do not reinterpret").

**T9 — End-to-end wiring + manual checklist** · `Run this on: Opus · high — multi-system glue; checklist prose is Sonnet-medium territory but rides along at Opus for the wiring judgment`
Files: touch-ups across T3–T7; authors the Phase 2 MANUAL-TEST-CHECKLIST section. Gate: offline acceptance evidence assembled; checklist handed to Erik.

**T10 — Fable adversarial review of the RT diff** · `Run this on: Fable · xhigh — locked pre-merge gate`
Input: combined T3+T5 (+T6 ring-reader) diff + this spec + gate evidence. Focus list: E16 flag pairing, E17 promotion window, E18 clamp math, E19 substitution completeness, E23/E15 grace ordering, E24 revalidation, fixed-point step rounding.

## 9. Reading order for builders
1. This spec top to bottom; then Phase 1 spec §2.2–§2.4, §A, §C, §F.
2. `ProcessTapController.swift:1-130` (doctrine), `:1348-1527` (`processMappedBuffers` incl. the chain insert + E1 flags), `:1546-1704` (callback: peak, gate, mute, role split), `:298-320` (`setAUChain` swap idiom).
3. `AUChainRenderState.swift` header + `render()` (the RT style to match), `AppAUChain.swift` header (release ordering) + `attach`/`rateChanged`/`releaseUnits`, `AUChainManager.swift` (registry shape to mirror).
4. `SettingsManager.swift:94-200` (schema idiom), `AudioEngine.swift:888-931` (attach wiring), `:2049` (BT re-rate).
5. `LoudnessDetector.swift` — only to see why it is not reusable (§2.1).
