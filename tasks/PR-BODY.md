# Phase 1: per-app Audio Unit plugin hosting

Open the PR here (one click, branch is already pushed):
https://github.com/droptheoars/FineTune/pull/new/feat/au-plugin-hosting

Title: `Phase 1: per-app Audio Unit plugin hosting`

---

Hosts AU effect plugins (AUv2 + AUv3) per application, inserted into the existing per-tap DSP
pipeline between the per-app EQ and the per-device AutoEQ correction.

Spec: `tasks/specs/2026-08-25-phase1-au-hosting.md`
Manual listening checklist: `tasks/MANUAL-TEST-CHECKLIST.md`

## What this adds
- Per-app plugin chains: add / remove / bypass / reorder, with real plugin UIs in floating windows
- A default chain for apps without their own, buildable from the UI via `Save as Default Chain`
- Persistence of plugin settings via AU `fullState`, keyed per app like EQ settings
- Plugin-reported latency surfaced with a lip-sync warning at >= 20 ms
- A curated `For listening` group at the top of the picker, with everything else still reachable

## Pipeline position
`volume -> EQ -> AU chain -> AutoEQ -> loudness -> soft limiter`

The chain sits before AutoEQ so distortion/saturation plugins generate content that still gets
headphone-corrected, and so Phase 2's ring buffer records pre-correction audio.

## Realtime safety
The audio thread only ever sees an immutable render plan through one atomic pointer, invoking
render blocks captured at build time against preallocated scratch. No allocation, blocking lock,
ObjC dispatch, or logging on that path.

Three defects found by an adversarial review of the realtime diff, all fixed here:
- **Critical**: the rate rebuild republished render blocks whose resources were already
  deallocated. Deterministic on any device switch with 2+ plugins: chain went silent, a healthy
  plugin could be spuriously auto-bypassed, and `allocateRenderResources` raced in-flight renders.
- Swift's bridged `au.renderBlock` allocates one malloc per render; the raw block is now extracted
  once at build time.
- `inputBusses[0].isEnabled` must be set before allocation or every render returns -10876 while
  the chain reports itself healthy.

## Tests
1005 passing, 39 covering the AU chain, including an offline harness that renders real Apple AUs.
The two invariants most likely to fail silently are proven by mutation:
- `rebuildNeverPublishesDeallocatedUnits` and the E15 ordering tests fail when the guard is removed
- five `AUChainCallbackScopeTests` each go red under a different deliberate break of the
  once-per-callback rule

## Not verified
No human has run this build yet. Every runtime claim is derived from code and tests, not observed.

## Known limitations
Chain is post-fader (volume moves pump dynamics plugins) · playback rate != 1.0 glitches until the
Phase 2 transport lands · plugins run in-process, so a plugin crash takes the app down.
