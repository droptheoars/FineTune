# Phase 1 — Audio Unit Hosting Spec

**Date**: 2026-08-25 · **Author**: Fable (architecture pass) · **Status**: Ready for build
**Scope**: Per-app AU effect chains (AUv2 + AUv3) inserted into the existing per-tap DSP pipeline.
**Locked upstream decisions honored**: app chain replaces default; chain UI in expanded app row; in-process hosting; SoftLimiter last; AU fullState persistence; floating real plugin windows; no new dependencies; plugin crash takes app down (v1).

---

## 1. Goals / Non-goals

### Goals
- Host any installed effect AU (AUv2 via the AUAudioUnit bridge, AUv3) per app, ordered, bypassable, reorderable.
- One default chain applied to every app without its own; a per-app chain fully replaces it.
- Real plugin windows (custom UI when the AU has one, generic parameter UI when it doesn't).
- Persistence via `fullState` blobs keyed by `persistenceIdentifier`, same as EQ settings.
- Survive: app relaunch, device switch (crossfade and destructive), A2DP↔SCO re-rate, tap health-recreate, plugin uninstalled.
- Plugin-reported latency surfaced in UI with a lip-sync warning.

### Non-goals (Phase 1)
- Playback-rate change on live streams (rate ≠ 1.0). Ruled to Phase 2 (§D). TimePitch/Varispeed are hostable and degrade boundedly; full speed control needs the ring-buffer transport.
- Multichannel (>2ch) taps: chain bypasses, same policy and one-time log as EQ (`maybeLogEQBypass`).
- MIDI, sidechains, AU factory-preset browsing (plugins expose their own presets in their own UI), inter-app instance sharing, out-of-process-first architecture, instrument AUs (`aumu`).
- Glitch-free reorder/bypass mid-audio (pointer swap causes a wet-path discontinuity; plugin state survives, accepted).

---

## 2. Architecture

### 2.1 Units and boundaries

```
Models/AUPluginConfig.swift        AUPluginConfig, AUChainConfig (Codable)          [new]
Audio/AUChain/AUChainRenderState.swift   RT-facing immutable render plan            [new]
Audio/AUChain/AppAUChain.swift     Per-app AU instance owner + lifecycle machine    [new]
Audio/AUChain/AUChainManager.swift Registry: identifier → AppAUChain; default chain [new]
Audio/Engine/ProcessTapController.swift  +setAUChain(_:), callback insert           [edit]
Audio/Engine/AudioEngine.swift     Wiring: attach on tap create, rate rebuild       [edit]
Settings/SettingsManager.swift     Settings v13: appAUChains, defaultAUChain        [edit]
Views/AUChainPanelView.swift       Effects panel in expanded row                    [new]
Views/Components/AUPluginPicker.swift    Installed-plugin picker popover            [new]
Views/AUPluginWindowController.swift     Floating NSPanel + view controller         [new]
Views/Rows/AppRow.swift            EQ|Effects mode toggle in expandedContent        [edit]
Views/MenuBarPopupView.swift       Plumb chain props/callbacks like EQ props        [edit]
```

Ownership: `AudioEngine` owns `AUChainManager`. `AUChainManager` owns one `AppAUChain` per app identifier (created lazily when a chain config exists or the default chain is non-empty). `AppAUChain` owns the `AUAudioUnit` instances — **not the tap**. Taps are disposable (recreated on device switch, health recovery, sleep/wake); AU instances and their internal state survive tap churn. A tap only ever holds a `nonisolated(unsafe)` pointer to an immutable `AUChainRenderState` built by the chain's owner.

### 2.2 Threading model

Three domains, matching the file-header doctrine in ProcessTapController.swift:

1. **MainActor** — all chain mutations, config persistence, render-state publication, plugin windows. `AppAUChain` and `AUChainManager` are `@MainActor`.
2. **Builder queue** — one serial `DispatchQueue(label: "AUChainBuilder", qos: .userInitiated)` for the blocking third-party calls: `allocateRenderResources()`, `deallocateRenderResources()`, bus-format sets, `fullState` set. Reached via `withCheckedContinuation` from MainActor; results published back on MainActor. Rationale: a hung plugin blocks this queue, not the UI and not audio (§E, hang watchdog). `AUAudioUnit.instantiate` is already async and callback-based.
3. **HAL I/O thread (RT)** — the only chain call allowed is `AUChainRenderState.render(...)`, which invokes stored `AURenderBlock`s and preallocated pull blocks. Invoking a block is a function-pointer call, not `objc_msgSend` on a dynamic selector — RT-acceptable. **Never** RT-callable: any `AUAudioUnit` property access, KVC/KVO, `fullState`, `allocateRenderResources`, format objects, `AVAudioFormat` creation.

Handoff mechanism (identical to the `loudnessEqualizerProcessor` idiom at ProcessTapController.swift:270): `nonisolated(unsafe) var auChainState: AUChainRenderState?` on the controller; main thread swaps the pointer (aligned pointer store, atomic on ARM64/x86-64), `OSMemoryBarrier()`, and defer-releases the old state via `DispatchQueue.global(qos: .utility).asyncAfter(.now() + 0.5)`. 0.5s ≫ worst-case buffer (4096 @ 44.1kHz ≈ 93ms), same justification as `BiquadSetupBox`.

### 2.3 AUChainRenderState — the RT contract

Immutable after build. Contents:

- `nodes: [Node]` — each Node stores: the `AURenderBlock` (captured once from `au.renderBlock` at build time, after `allocateRenderResources`), a preallocated pull block bound to fixed scratch pointers, reported latency in samples, and a `nonisolated(unsafe) var nanStrikes: Int32` counter.
- Two ping-pong deinterleaved stereo scratch ABLs (Float32, 4096-frame capacity), assigned to nodes by index parity at build time so every pull block's source pointer is fixed.
- Interleaved staging in/out scratch (4096 × 2 Float32).
- `nonisolated(unsafe) var sampleTime: Int64` — running timestamp, advanced by frameCount per successful render; `AudioTimeStamp` with `.sampleTimeValid` reused from a preallocated var.
- `builtSampleRate: Double`, `totalLatencySamples: Int`, `gate: os_unfair_lock` (used **only** via `os_unfair_lock_trylock` / `unlock` within one callback invocation — never blocks, no priority inversion).
- Per-cycle pull bookkeeping: read offset + provided-frame count per node, plus `nonisolated(unsafe)` under/over-consumption counters (§D detection).

```swift
final class AUChainRenderState {   // RT-facing; immutable topology after build
    /// Returns false when the buffer passed through dry (gate contention or empty chain).
    func render(interleavedStereo: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool
}
```

`render` flow: trylock gate (fail → return false, dry passthrough, **not** zeroed) → slice loop over `min(remaining, 4096)` frames → `vDSP_ctoz` deinterleave into scratch A → for each node: set pull bookkeeping, invoke render block (input pulled from parity scratch, output into the other) → per-node NaN check on sample 0 of both channels (NaN/inf → zero that node's output slice, `nanStrikes += 1`; else reset to 0) → `vDSP_ztoc` interleave back in place → advance `sampleTime` → unlock. No allocation, no locks (trylock is non-blocking), no ObjC dispatch, no logging.

Pull block contract: serves the node's input scratch at the per-cycle offset; multiple partial pulls summing to ≤ frameCount are served; a pull past the provided frames zero-fills and bumps the underflow counter; a cycle that consumes < provided bumps the overconsumption... — correction: consumes-less bumps the *underconsumption* counter (input discarded). Counters are polled from MainActor (§D badge, §E auto-bypass).

### 2.4 Pipeline insert point — ruling on the slot

**Ruling: the chain inserts after EQProcessor, BEFORE AutoEQProcessor** (not the suggested after-AutoEQ slot). The invited argument:

1. **Domain layering.** Volume, EQ, and the AU chain are *per-app creative* stages; AutoEQ, LoudnessEqualizer, LoudnessCompensator, SoftLimiter are *per-device/per-ear corrective* stages. Grouping app-domain → device-domain is the clean invariant.
2. **Correction must be last.** AutoEQ linearizes the headphone. Distortion/saturation plugins (RC-20, Cassette — the two acceptance plugins) generate new spectral content; placed after AutoEQ that content bypasses the correction curve. Placed before, everything the ear receives is corrected.
3. **Phase 2 ring placement.** The ring buffer sits upstream of the chain (locked, §F). With the chain pre-AutoEQ, the ring records the per-app creative signal; rewound audio replayed later gets the *current* device's AutoEQ/loudness — correct across a mid-rewind headphone switch. With the chain post-AutoEQ, the ring would bake in the old device's correction.

Resulting order in `processMappedBuffers`: gain(volume × crossfade × gate) → EQ → **AU chain** → AutoEQ → LoudnessEqualizer → LoudnessCompensator → SoftLimiter (unchanged last). Chain runs under the same `eqCanProcessStereoInterleaved` gate as EQ (stereo in/out only).

**Once-per-callback invariant** (found in audit, §8-E1): `processMappedBuffers` loops over output buffers; a stacked mirroring aggregate presents one stereo buffer per sub-device, and today EQ runs once per buffer. A stateful, time-consuming AU chain must render exactly once per callback or time-based effects run at 2×. Rule: chain renders on the first eligible buffer; subsequent eligible buffers in the same callback receive a `memcpy` of the chain's interleaved output scratch (contents are identical by construction — mirroring), `min`-length with zero-fill.

Chain is **post-fader** (gain is applied at the copy stage, upstream). Dynamics-type plugins will react to FineTune volume moves like post-fader inserts in a DAW. Documented limitation (§8-E3); not restructuring the gain stage in v1.

### 2.5 Lifecycle state machine

Per plugin slot, owned by `AppAUChain` (@MainActor). Bypass is a config flag, orthogonal to lifecycle.

```
empty ──instantiate──▶ instantiating ──ok──▶ configuring ──ok──▶ allocating ──ok──▶ ready
                          │fail                  │fail               │fail/timeout
                          ▼                      ▼                   ▼
                       failed(.missing)   failed(.formatRefused   failed(.allocFailed
                                                 |.stateRestore)         |.hung)
ready ──rateChange──▶ allocating (dealloc → set formats → realloc; same instance, state kept)
any ──remove──▶ released (fullState captured first if ready)
```

- **instantiating**: `AUAudioUnit.instantiate(with: desc, options: [.loadInProcess])`; on failure retry once with `[]` (lets an in-process-refusing AUv3 fall back to Apple's extension process — this keeps the *architecture* in-process for everything that supports it, which is all AUv2 in an unsandboxed host, while not hard-failing strict AUv3s; their render blocks are still RT-callable). Component not found → `failed(.missing)`, slot kept in order, blob kept (§E).
- **configuring** (builder queue): set `maximumFramesToRender = 4096` **before** allocation; set input/output bus formats to `AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)` (deinterleaved Float32 — the canonical format every AU must accept); restore `fullState` if a blob exists (plist-decoded, §5). Format set throws → `failed(.formatRefused)`. State restore throws → plugin continues with defaults, badge, `failed` is NOT entered (audio still works) — slot is `ready` with `stateRestoreFailed` flag for the UI.
- **allocating** (builder queue): `allocateRenderResources()`, watchdog 5s (§E). Then capture `renderBlock` once.
- **ready**: participates in render-state builds.

Chain-level operations:
- **Render-state build** (cheap, MainActor): snapshot ready+unbypassed slots in order, assemble Node array + scratch, compute `totalLatencySamples = Σ round(au.latency × sampleRate)`, publish via `setAUChain`. Triggered by: slot reaches ready, bypass toggle, reorder, remove, rate rebuild completion. No AU calls involved beyond reading `latency`/`renderBlock` (cached at allocation).
- **Rate rebuild** (device switch / A2DP↔SCO): `setAUChain(nil)` first (chain drops out; the destructive path is under `_forceSilence` anyway), then per slot on the builder queue: dealloc → set formats at new rate → realloc → new render state published. Instances and their internal state survive; open plugin windows stay open. If audio resumes before the rebuild lands, buffers pass dry until the swap — accepted transient, typically shorter than the destructive path's 80–150ms settle + 200ms volume ramp.

### 2.6 Tap wiring

- `ProcessTapController` gains `func setAUChain(_ state: AUChainRenderState?)` (swap idiom §2.2) and `var nominalSampleRate: Double?` (reads `primaryResources.aggregateDeviceID.readNominalSampleRate()`).
- Attach point: inside `ensureTapExists` / `ensureTapWithDevices` (both creation paths, so health-recreate and sleep/wake recreation inherit it — §8-E14): after `activate(initial:)`, `auChainManager.attach(to: tap, identifier: app.persistenceIdentifier, sampleRate: tap.nominalSampleRate)`. The chain builds asynchronously; the tap runs chain-less until the state arrives — the exact pattern of the async AutoEQ resolve (AudioEngine.swift:870).
- `performDeviceSwitch` (destructive) and `recreateForOutputRateChange` already funnel rate changes; AudioEngine's `handleBTDeviceSampleRateChanged` additionally calls `auChainManager.rateChanged(identifier:newRate:)` for affected apps. A general guard: `attach` compares `state.builtSampleRate` to the tap's rate and rebuilds on mismatch, so any path that lands on a different-rate device self-heals.
- App disappears from the app list → `AppAUChain` captures fullState, deallocates, releases instances, closes its windows. Recreated on demand from config.

---

## 3. Rulings A–F

### A. RT safety — ruled in §2.2/§2.3/§2.5
Everything that can block, allocate, or message ObjC happens on MainActor or the builder queue; the RT thread sees only an immutable render plan through one atomic pointer, invokes stored blocks, and touches preallocated scratch. Acceptable on RT: invoking `AURenderBlock` and pull blocks, `vDSP_ctoz`/`ztoc`, `os_unfair_lock_trylock` (never blocks), aligned atomic loads/stores, `OSMemoryBarrier`. Forbidden: all `AUAudioUnit` property access, format objects, fullState, alloc/dealloc of render resources, logging. The state machine (§2.5) guarantees `renderBlock` is only ever captured after `allocateRenderResources` succeeded and is never invoked after `deallocateRenderResources` begins (the nil-swap + 0.5s grace precedes dealloc on the builder queue — the builder must wait out the grace period before deallocating: sequence `setAUChain(nil)` → sleep ≥ 0.5s on builder queue → dealloc).

### B. Buffer format shim — ruled in §2.3
Interleaved stereo Float32 (pipeline) ↔ deinterleaved stereo Float32 (canonical AU format): one `vDSP_ctoz` in, ping-pong scratch between nodes, one `vDSP_ztoc` out. 4096-frame scratch; larger callbacks processed in slices (no silent bypass). Channel-count changes: chain is stereo-gated like EQ; non-stereo taps bypass with the existing one-time log. Sample-rate changes ride the destructive-switch path with the nil-swap + rebuild sequence (§2.5); the A2DP↔SCO path is covered because `recreateForOutputRateChange` routes through it.

### C. Crossfade — ruled: primary-only chain + trylock ownership gate
AU instances cannot be duplicated for the secondary tap (no cheap sync copy; fullState clone is neither sample-accurate nor RT-safe), and sharing across two concurrent HAL threads is a data race inside third-party code. Rejected: shadow pre-instantiated chain (2× CPU/memory, state still diverges, cost paid on every switch for a 50ms window).

**Ruling**: during crossfade the secondary tap runs EQ/AutoEQ/loudness duplicates exactly as today but **no AU chain**. The chain renders only in primary role. The promotion race (old primary's in-flight callback still inside `render` while the promoted callback enters, a ~one-buffer window) is closed by the render state's trylock gate: whoever holds it renders wet; the loser passes that buffer dry. Never blocks, worst case one dry buffer (~5ms).

Audible consequence, stated honestly: for `CrossfadeConfig.duration` = 50ms the output is a blend of wet (fading out) and dry (fading in); after promotion the chain re-attaches to the promoted callback with **all plugin state intact** (same instances — no reverb-tail reset, no wow/flutter phase reset). During BT warmup (up to 300ms) the secondary is muted anyway, so the dry exposure is the 50ms blend plus the first post-promotion buffers. If the chain reports latency, wet and dry are time-misaligned by that latency during the 50ms blend — a transient comb/slap proportional to chain latency (§8-E2). Accepted for v1: device switches are rare, the window is small, and every alternative is worse or unsafe.

Secondary-callback rule in code terms: the callback passes `auChainState` into `processMappedBuffers` only when `isPrimary`; secondary passes nil. Promotion needs no chain pointer swap — the state is role-agnostic and gate-protected.

### D. Rate-changing AUs — ruled: OUT of Phase 1; bounded degradation + detection in the meantime
Physics: the tap is push-driven at realtime; TimePitch/Varispeed at rate r pull r×N input per N output. r<1 → unread input discarded every cycle (chunky slow-motion with jump-cuts); r>1 → underflow zero-fill (stutter). Any "bounded interim" ring without a transport either overflows (jump-cut forward) or starves — it cannot be made to sound right, only to fail politely.

**Ruling**: (1) Live rate ≠ 1.0 is **Phase 2**, where the ring-buffer transport sits upstream and the chain is fed from the transport's read head — the Phase 2 spec MUST feed AU chains from the ring read head at device rate (§F seam). (2) TimePitch (`aufc`/`nutp`/`appl`) and Varispeed (`aufc`/`vari`/`appl`) — note: **format converters, not effects** — are still hostable in Phase 1: they instantiate, open windows, persist, and render cleanly at rate 1.0 (pulls exactly N in steady state). At rate ≠ 1.0 the pull bookkeeping detects sustained mismatch (≥10 consecutive cycles, ignoring priming transients) and the UI shows the speed badge (copy pinned §6.4); audio degrades as described — bounded, no memory growth, no crash. (3) The plugin picker lists effect + musicEffect types, plus exactly these two converters under a "Speed" group with the same caveat (§6.3). Acceptance tests adjusted accordingly (§9).

### E. Failure modes — rulings
- **Instantiate fails at restore (uninstalled/moved)**: slot → `failed(.missing)`, keeps its position (grayed row, badge "Not installed"), blob kept — reinstalling and relaunching (or re-adding) revives it. Chain builds around it.
- **fullState restore fails**: Swift-thrown error → plugin loads with defaults + row badge "Settings couldn't be restored"; blob kept until the next capture overwrites it. A plugin that raises an ObjC exception inside the setter crashes the app — same accepted in-process posture as a render-thread crash; CrashGuard destroys the aggregates.
- **Latency**: `totalLatencySamples` computed at each render-state build from `au.latency`; shown in the panel header as "≈ N ms"; at ≥ 20ms an exclamation badge with the lip-sync warning (copy §6.2). Recomputed only on builds — a plugin toggling lookahead mid-session shows stale numbers until the next chain edit (accepted, §8-E12).
- **Hang in allocateRenderResources**: builder-queue call raced against a 5s MainActor timeout. On timeout: slot → `failed(.hung)`, badge "Not responding"; the wedged serial queue is abandoned and a fresh builder queue is created so other chains keep working. The zombie thread leaks by design (killing threads is worse).
- **NaN/inf**: SoftLimiter does NOT stop NaN (`abs(NaN) <= threshold` is false → NaN propagates through `apply`). Ruling: per-node output scrub in `render` (§2.3) — sample-0 check both channels, zero the offending node's output slice, count strikes. MainActor polls strike counters (existing 2s health cadence); ≥ 100 consecutive strikes → auto-bypass that slot, badge "Disabled: produced invalid audio", rebuild. This both protects ears and attributes the culprit, which a chain-exit-only scrub cannot.
- **Build lands on a stale device**: every render-state carries `builtSampleRate`; publication compares against the tap's current rate and rebuilds instead of publishing on mismatch (device switched mid-build).

### F. Phase 2 seam — named
The seam is the `AUChainRenderState.render(interleavedStereo:frameCount:)` boundary plus the insert point. Invariants Phase 1 must keep so Phase 2 never reopens it:
1. `render` takes an explicit buffer + frame count and reads **nothing** from tap state — no assumption its input is the live tap signal.
2. The insert point (post-EQ, pre-AutoEQ) is exactly where the ring buffer's write (tap side) and the transport's read (chain side) will split the pipeline: tap writes post-EQ audio to the ring; the transport produces N device-rate frames per callback (consuming ring content at rate r); the chain renders those N frames; AutoEQ/loudness/limiter continue live. The chain call itself does not move.
3. Rate-mismatch bookkeeping (§D) stays: in Phase 2 the transport, not the AU, owns the rate, and the counters become a transport-health diagnostic.

---

## 4. Persistence schema

`SettingsManager.Settings` bumps to `version: 13`. Additions (all `decodeIfPresent` with defaults, matching every existing field):

```swift
struct AUPluginConfig: Codable, Equatable {
    var id: UUID                      // stable slot identity (window autosave, badges)
    var componentType: UInt32         // AudioComponentDescription triple
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var displayName: String           // shown when the component is missing
    var isBypassed: Bool
    var fullState: Data?              // binary plist (PropertyListSerialization) of AUAudioUnit.fullState
}
struct AUChainConfig: Codable, Equatable { var plugins: [AUPluginConfig] }

// Settings v13:
var appAUChains: [String: AUChainConfig] = [:]  // persistenceIdentifier → custom chain
var defaultAUChain: AUChainConfig? = nil
```

Semantics:
- **Absence** of a key in `appAUChains` = app follows the default chain. **Presence with empty `plugins`** = explicitly "no effects" (replaces default with nothing). This distinction is required by the locked replace-never-stack decision.
- Each app on the default chain gets its **own instances** built from `defaultAUChain` (instances are never shared across taps). Structural edits (add/remove/reorder/bypass) on an app that follows default **fork** a per-app copy first (§6.2 copy). Parameter tweaks inside a plugin window on a default-chain instance are captured back into `defaultAUChain` — two apps' windows tweaking the same default plugin = last capture wins (accepted, §8-E7).
- **Capture triggers** for `fullState`: plugin window close; any structural chain edit; app-termination `flushSync`; a 60s timer while any plugin window is open; before an `AppAUChain` releases its instances. Erik's tweak-loss window is therefore ≤ 60s on force-quit.
- SettingsManager accessors follow the house pattern: `getAUChain(for:)`, `setAUChain(_:for:)`, `clearAUChain(for:)` (returns app to default), `defaultAUChain` get/set — every setter ends in `scheduleSave()`. `ignoreApp` and `pruneStaleSettings` gain `appAUChains` removal (prune only when the chain is absent/empty; a configured chain is user intent, kept like device routing). `resetAllSettings` clears both.

---

## 5. UI spec

All copy below is pinned. Builders paste; they do not write.

### 5.1 Expanded app row — mode toggle
The `expandedContent` of `AppRow`'s `ExpandableGlassRow` gains the existing `ModeToggle` component at top with two segments: **`EQ`** and **`Effects`**. EQ segment shows today's `EQPanelView` unchanged. Selection is per-row `@State`, defaulting to `EQ`. The row's expand button (`slider.vertical.3` in AppRowControls) behavior is unchanged — one expanded row at a time via `expandedRowID`, Escape order unchanged.

### 5.2 Effects panel (`AUChainPanelView`)
Top-to-bottom:
1. **Header row**: left — source label: `Default chain` or `Custom chain` (9pt, `textTertiary`, same style as the routing subtitle). Center — latency: `≈ 12 ms` when `totalLatencySamples > 0`; at ≥ 20ms prepend `exclamationmark.triangle.fill` (yellow) with tooltip: `This chain delays audio by about N ms. Video lip-sync may drift.` Right — overflow menu (`ellipsis.circle`): custom chain shows `Use Default Chain` (destructive-ordering last: `Remove All Effects`); default chain shows only `Remove All Effects` (edits the default; confirm sheet not needed — undo is re-adding).
2. **Plugin rows**, in signal order (top = first). Each row: drag handle (`line.3.horizontal`, drag to reorder) · plugin name (+ manufacturer, 9pt tertiary) · state badge (see below) · bypass toggle (`power` icon button; bypassed renders the row at 50% opacity; tooltip `Bypass` / `Enable`) · open-window button (`macwindow`, tooltip `Open plugin window`) · remove button (`xmark`, hover-only, tooltip `Remove`).
   - Badges: missing → `exclamationmark.triangle` + `Not installed` · restore-failed → `Settings couldn't be restored` · hung → `Not responding` · NaN-disabled → `Disabled: produced invalid audio` · sustained rate mismatch → `speedometer` + tooltip `This plugin changes playback speed. Full speed control arrives with the recorder (Phase 2); at other speeds audio will glitch.`
3. **Empty state** (chain has no plugins): `No effects. Audio passes through unchanged.` (centered, tertiary).
4. **Add row**: `plus.circle` + `Add Effect` → opens the picker (§5.3).
5. **Fork rule**: the first structural edit while on the default chain silently forks (per locked "replaces, never stacks"), and the header label flips to `Custom chain` with a one-time inline note under the header, auto-dismissing on next expand: `This app now has its own chain. The default chain no longer applies here.`

### 5.3 Plugin picker (`AUPluginPicker`)
Popover anchored to the Add row (use `PopoverHost`/`DropdownMenu` idioms). Search field placeholder: `Search effects…`. Content: `AVAudioUnitComponentManager.shared().components(matching:)` for types `kAudioUnitType_Effect` and `kAudioUnitType_MusicEffect`, grouped by manufacturer, alphabetical; plus a trailing group **`Speed`** containing exactly Apple TimePitch and Apple Varispeed, with footnote text: `Speed plugins work fully in a later update. At speeds other than 1.0, audio will glitch.` Row: name + manufacturer. Click = append to chain end, close picker, begin instantiation (row appears immediately with a progress spinner in the badge slot until `ready`).

### 5.4 Floating plugin window (`AUPluginWindowController`)
- One window per plugin slot (`id`-keyed). Open button focuses the existing window if already open.
- `NSPanel`, styleMask `[.titled, .closable, .resizable]`, `level = .floating`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, frame autosave name `AUWindow-<slot UUID>`.
- Title: `<Plugin Name> — <App Name>`.
- Content: `au.requestViewController { vc in ... }` on main. The AUv2 bridge serves wrapped Cocoa custom UIs through the same call. `nil` result → fall back to `AUGenericViewController` (CoreAudioKit) bound to the audio unit. Both failing → alert-styled placeholder inside the window: `This plugin has no interface FineTune can display.` (window still hosts bypass state; parameters unreachable — rare).
- Closing the window never removes the plugin or changes bypass; it triggers a fullState capture (§4).
- Windows close automatically when: their slot is removed; the chain is reset to default; the app's `AppAUChain` is released (app left the list). Windows **survive** device switches and rate rebuilds (same instance).

---

## 6. Edge-case audit (lifecycle / cross-system findings)

- **E1 Mirrored-output double render** — stacked multi-device aggregates deliver one stereo buffer per sub-device; today EQ runs per buffer (harmless, biquads see identical content). A stateful chain rendered per buffer would run time-based effects at 2× and double CPU. Ruled: once per callback + memcpy (§2.4). This is a must-verify in the RT review.
- **E2 Crossfade wet/dry comb** — during the 50ms blend, wet (latency-delayed) and dry are misaligned by chain latency; audible as a transient slap with high-latency chains. Accepted; documented in §C. Do not "fix" by delaying dry — not worth RT machinery for 50ms.
- **E3 Post-fader chain** — FineTune volume moves pump dynamics-type plugins (RC-20 compressor reacts to fader). Known limitation; revisit only if it annoys in practice.
- **E4 Tweak-loss window** — force-quit loses plugin-window tweaks since the last capture (≤ 60s). Accepted; `flushSync` covers normal quit.
- **E5 Window vs. instance lifetime** — every path that releases instances must close their windows first (fork keeps instances, so no window churn on fork; reset-to-default and app-left-list must close). Builder checklist item.
- **E6 A2DP↔SCO with window open** — instance survives dealloc/realloc; most views tolerate it. If a specific AUv3 view disconnects, reopening the window is the remedy; not engineering around it in v1.
- **E7 Default-chain capture contention** — two apps' windows on the same default plugin: last capture wins. Accepted and documented (§4).
- **E8 CrashGuard interplay** — none needed: chain crash = process crash → existing signal handler destroys tracked aggregates. Do not add chain teardown to the signal path (not async-signal-safe).
- **E9 Priming false positives** — latency plugins may briefly pull irregularly on their first cycles; the ≥10-consecutive-cycle threshold on mismatch detection ignores priming (§D).
- **E10 Target app quits** — tap dies with it; `AppAUChain` captures state and releases when the app leaves the list; windows close; chain rebuilds from config on next launch of that app. Verify no capture-after-dealloc ordering bug (capture BEFORE dealloc on the builder queue).
- **E11 Oversized callbacks** — frameCount > 4096 is sliced, never silently bypassed (§2.3).
- **E12 Stale latency display** — recomputed on builds only; accepted (§E).
- **E13 Reorder mid-audio** — atomic swap; wet discontinuity possible, plugin state preserved; accepted.
- **E14 Every tap-creation path attaches the chain** — attach lives inside `ensureTapExists`/`ensureTapWithDevices`, which health-recreate, sleep/wake, and applyPersistedSettings all funnel through. Guard: attach also on `updateDevices` completion via the rate-mismatch self-heal (§2.6).
- **E15 Builder-queue grace ordering** — dealloc must wait out the 0.5s render-state grace after nil-swap (§A). Violation is a use-after-free on the RT thread with no crash until it ships. Fable review item #1.

---

## 7. Acceptance tests (adjusted per ruling D)

1. **RC-20 on Spotify**: add via picker → real UI opens in floating window → tweak character knobs → audio audibly processed → quit + relaunch FineTune → chain restored with identical settings (audible + knob positions) → window reopens on click.
2. **Wavesfactory Cassette on browser audio** (Chrome or Safari tab audio): same add/process/persist cycle.
3. **TimePitch (speed-without-pitch)**: hosts, window opens, renders clean at rate 1.0. Setting rate ≠ 1.0 → speed badge appears within a few seconds; audio degrades but does not crash, leak, or grow memory. Full speed control is a Phase 2 acceptance item (transport-fed chain).
4. **Varispeed (speed-with-pitch)**: same as 3.
5. **Default chain**: configure default chain with one plugin; every app without a custom chain processes through its own instance; survives a device switch (BT ↔ built-in both directions) with plugin state continuity; the switch exhibits at most the documented ≤ ~350ms chain-dry window on the incoming device.
6. **Failure drill**: uninstall (move away) a persisted plugin → relaunch → `Not installed` badge, slot and blob retained, rest of chain works; restore the plugin → re-add works with old state.
7. **Regression**: EQ, AutoEQ, loudness EQ/compensation, limiter, VU meters, crossfade device switch, and A2DP↔SCO call transition all behave as before with an active chain (and with chain bypassed).

---

## 8. Build decomposition

Order is dependency order; T5–T7 parallelize after T4. Reviewer ≥ builder; deterministic gates run before any model review. One Fable adversarial review of the combined RT diff (T2+T4) before merge — locked in the project plan.

**T1 — Models + persistence** · `Run this on: Sonnet · medium — fully pre-decided Codable + accessor work`
Files: `Models/AUPluginConfig.swift` (new), `Settings/SettingsManager.swift`, `FineTuneTests/AUChainConfigTests.swift` (new).
Pre-decided: schema §4 verbatim, v13 bump, decodeIfPresent defaults, accessor names, prune/ignore/reset integration. Judgment: none.
Gate: `xcodebuild -scheme FineTune test` green; round-trip + v12-payload decode tests pass.

**T2 — AUChainRenderState (RT keystone)** · `Run this on: Fable · xhigh — the one keystone module: pull-block memory model, gate, scratch layout become everyone's invariants; failures are silent-wrong`
Files: `Audio/AUChain/AUChainRenderState.swift` (new), `FineTuneTests/AUChainRenderStateTests.swift` (new).
Pre-decided: §2.3 contract, §A allowed-call list, ping-pong parity, slice loop, NaN scrub, trylock gate, counters. Judgment: exact pull-block/ABL mechanics.
Gate: offline XCTest harness rendering sine/impulse through real Apple AUs (AUDelay, AUNewTimePitch@1.0): bit-exact dry pass on empty chain, latency reporting, underflow counters on forced short-serve, NaN scrub with a stub node.

**T3 — AppAUChain + AUChainManager lifecycle** · `Run this on: Opus · high — correctness-critical async lifecycle, third-party code, watchdog`
Files: `Audio/AUChain/AppAUChain.swift`, `Audio/AUChain/AUChainManager.swift` (new), lifecycle tests.
Pre-decided: state machine §2.5, builder-queue discipline, watchdog + queue abandonment, capture triggers §4, default-chain fork semantics, E10/E15 ordering. Judgment: continuation plumbing details.
Gate: tests for instantiate-missing, format-refused (stub), restore-failed, watchdog (injected blocking closure), capture-before-release ordering.

**T4 — RT integration: ProcessTapController + AudioEngine** · `Run this on: Opus · high — the RT lane; then Fable adversarial review of the T2+T4 diff before merge`
Files: `Audio/Engine/ProcessTapController.swift`, `Audio/Engine/AudioEngine.swift`.
Pre-decided: swap idiom §2.2, insert point §2.4, once-per-callback rule E1, primary-only + nil-for-secondary §C, attach points §2.6, rate-rebuild triggers, 0.5s grace before dealloc E15. Judgment: minimal-diff placement inside `processMappedBuffers`.
Gate: build + full existing test suite green (CrossfadeStateAdversarial etc. untouched) + manual RT protocol: Console.app clean of chain logs on the HAL thread; acceptance test 7.

**T5 — Effects panel UI** · `Run this on: Sonnet · medium — pinned spec §5.1–5.2, existing components (ModeToggle, ExpandableGlassRow, DesignTokens)`
Files: `Views/AUChainPanelView.swift` (new), `Views/Rows/AppRow.swift`, `Views/MenuBarPopupView.swift`, preview.
Brief: match §5 exactly, paste all copy, do not reinterpret. Gate: build + Previews render + walkthrough checklist (badges, fork note, empty state, latency badge threshold).

**T6 — Plugin picker** · `Run this on: Sonnet · medium — pinned spec §5.3, existing popover idioms`
Files: `Views/Components/AUPluginPicker.swift` (new).
Gate: build + walkthrough: search, grouping, Speed group + footnote, spinner-until-ready.

**T7 — Plugin window controller** · `Run this on: Opus · high — v2 Cocoa bridging + AUv3 VC + generic fallback is integration-subtle`
Files: `Views/AUPluginWindowController.swift` (new).
Pre-decided: §5.4 verbatim. Judgment: VC embedding/resize edge cases per plugin.
Gate: manual matrix — one AUv2 with Cocoa UI (RC-20), one AUv3, one no-UI Apple AU (generic fallback), autosave frames, close-capture trigger firing.

**T8 — End-to-end wiring + latency/badge polish** · `Run this on: Opus · high — multi-system: manager ↔ engine ↔ UI ↔ persistence`
Files: touch-ups across T3–T7 files only.
Gate: acceptance tests 1–6 executed and evidenced (screen recording or logged checklist).

**T9 — Fable adversarial review of the RT diff** · `Run this on: Fable · xhigh — locked pre-merge gate`
Input: combined T2+T4 diff + this spec + T4 gate evidence. Focus list: E1, E15, gate correctness at promotion, nil-swap ordering on rate change, pull-block aliasing.

---

## 9. Reading order for builders
1. This spec top to bottom.
2. `ProcessTapController.swift:1-130` (threading doctrine), `:1317-1472` (`processMappedBuffers`), `:1491-1641` (callback).
3. `BiquadProcessor.swift` (swap + deferred destruction idiom), `EQProcessor.swift`.
4. `SettingsManager.swift` (accessor + Codable idioms), `TapInitialState.swift`, `AudioEngine.swift:1051-1240` (tap creation), `:1983-1998` (rate change).
5. UI tasks: `AppRow.swift`, `EQPanelView.swift`, `Components/ModeToggle.swift`, `MenuBarPopupView.swift:900-1040`.
