# FineTune fork — Erik's adjusted version

**Fork**: github.com/droptheoars/FineTune (upstream: ronitsingh10/FineTune, GPL-3.0)
**Local**: ~/Code/Personal/FineTune
**Status**: Phase 1 spec COMPLETE (Fable, 2026-08-25) → tasks/specs/2026-08-25-phase1-au-hosting.md. Awaiting Erik's spec review before build.

## License note
GPL-3.0. Private use: no obligations. Distributing builds to others: source must be public under GPL.

## Already exists upstream (no work needed)
- Device hiding: pencil (edit mode) → eye icon per device row. Can't hide current default device.

## Roadmap (approved)

### Phase 1 — AU plugin hosting (the spine) [SPEC IN PROGRESS]
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

### Phase 2 — Ring buffer + tape transport
Per-app ring buffer (opt-in; ~23 MB/min/app full quality) enabling:
- I1 Rewind live audio (OB-4 style) — scrub into the past, catch up to live
- I2 Tape mode — varispeed read head, pitch follows speed; tape stop/brake; real-time music slowdown
- I3 Retro-record — "save the last N minutes" after the fact (relates to improv-capture idea)
- I10 Loop grab — mark + loop a chunk, OP-1 style
- Transport UI (scrub bar on app row) — decision mockup needed (design lane, novel surface)

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
- [ ] T1 models + persistence (Sonnet) — dispatched
- [ ] T2 AUChainRenderState (Fable) — dispatched
- [ ] T3 AppAUChain + AUChainManager (Opus)
- [ ] T4 RT integration (Opus)
- [ ] T5 effects panel UI (Sonnet)
- [ ] T6 plugin picker (Sonnet)
- [ ] T7 plugin window controller (Opus)
- [ ] T8 end-to-end wiring (Opus)
- [ ] T9 Fable adversarial review of T2+T4 RT diff

**Decisions taken during build**
- D1: `ModeToggle` is hard-bound to `DeviceSelectionMode`. T5 may generalize it ONLY if no
  existing call site changes; otherwise a local segmented control in the new panel file,
  visually identical. Spec §5.1's intent is visual consistency, not literal reuse.
