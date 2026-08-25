Build Phase 1 of my FineTune fork: per-app AU plugin hosting. Run it to completion, do not stop at 80%.

START HERE
1. Read tasks/current-plan.md (roadmap + my locked decisions).
2. Read tasks/specs/2026-08-25-phase1-au-hosting.md IN FULL (305 lines). It is the contract:
   rulings A-F, persistence schema, pinned UI copy, edge-case audit, tasks T1-T9 with tiers/gates.
3. We are on branch feat/au-plugin-hosting. Spec + plan are committed (62a20a4).
4. T0 baseline: `xcodebuild -scheme FineTune -configuration Debug build` and run the existing
   test suite BEFORE touching anything. If baseline is already broken, tell me and stop.

HOW TO RUN IT
- Use superpowers:executing-plans + the unlazy skill. You orchestrate, subagents build.
- Task order and model tiers are pinned in the spec's build decomposition:
  T1 models/persistence = Sonnet medium · T2 AUChainRenderState (RT keystone) = Fable xhigh ·
  T3 lifecycle manager = Opus high · T4 ProcessTapController/AudioEngine integration = Opus high ·
  T5 effects panel UI = Sonnet medium · T6 plugin picker = Sonnet medium ·
  T7 plugin window controller = Opus high · T8 end-to-end wiring = Opus high ·
  T9 Fable xhigh adversarial review of the combined T2+T4 realtime diff BEFORE merge.
  T5/T6/T7 can run in parallel after T4.
- Every task: brief with files + constraints + verification command. Run its gate before moving on.
  No task is done until its gate passes. Report gate output, never "should work".
- Commit after each task passes its gate (conventional prefix). Update tasks/current-plan.md from
  the main thread only, never from a subagent.
- After 2 failed fix attempts on anything: stop, read the whole relevant section, re-plan at Fable
  tier before attempt 3.

VERIFICATION — the part that actually ends the loop
Automated: builds clean, existing suite green, new tests green (T2 has an offline XCTest harness
rendering real Apple AUs; codable round-trip for T1; injected-hang lifecycle tests for T3).
Manual (needs my ears, so prepare it, don't fake it): acceptance tests from the spec —
RC-20 on Spotify with settings surviving relaunch and its window opening; Wavesfactory Cassette on
browser audio; TimePitch and Varispeed hosting cleanly at rate 1.0; default chain on every app
surviving a device switch to AirPods and back.
When automated gates are all green, build the app, hand me a numbered click-by-click manual test
checklist, and tell me exactly what to listen for. That handoff is the end of the loop.

KNOWN TRAPS (from the spec's audit — do not rediscover these the hard way)
- E1: stacked mirroring aggregates deliver one buffer per sub-device. Chain renders ONCE per
  callback, later buffers memcpy. Rendering per buffer runs time-based effects at 2x speed.
- E15: after the nil-swap, dealloc on the builder queue must wait out the 0.5s grace or it is a
  silent use-after-free.
- Chain renders on the PRIMARY tap only; secondary stays dry through crossfade.
- Rate != 1.0 on live streams is Phase 2 work. Do not try to make it work now.

Ask me only when genuinely blocked or when a decision changes what ships. Otherwise keep going.
