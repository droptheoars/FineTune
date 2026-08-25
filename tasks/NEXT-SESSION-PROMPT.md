Phase 2 of my FineTune fork: ring buffer + tape transport. This session is the SPEC session —
architecture pass first, no building until the spec is approved. Same discipline that made
Phase 1 land: Fable architecture pass -> my review -> build decomposition with pinned tiers.

CONTEXT
1. Read tasks/current-plan.md — Phase 1 is WORKING (verified by ear 2026-08-25). Branch
   feat/au-plugin-hosting at c1b331f, pushed. Phase 2 builds ON this branch or on a new
   feat/tape-transport branched from it — your call, tell me which and why.
2. Read tasks/specs/2026-08-25-phase1-au-hosting.md §F "Phase 2 seam" IN FULL. It is a LOCKED
   contract: the ring buffer writes post-EQ audio at the exact point where the AU chain renders
   today; the transport produces N device-rate frames per callback (consuming ring content at
   rate r); the AU chain is fed FROM THE TRANSPORT READ HEAD, not the live tap; the chain call
   itself does not move; AutoEQ/loudness/limiter stay live and untouched.
3. Phase 1 findings that Phase 2 inherits (all in current-plan.md): the raw-render-block
   extraction (never use bridged au.renderBlock), input-bus enable before allocate, the
   demote-before-rebuild rule on rate change, hardened-runtime entitlement, E1 once-per-callback.

WHAT PHASE 2 IS (approved roadmap, tasks/current-plan.md)
Per-app ring buffer (opt-in, ~23 MB/min/app full quality) + a tape transport reading from it:
- I2 Tape mode: varispeed read head — REAL speed change of live music, pitch following speed
  (and TimePitch for speed-without-pitch), tape stop/brake. This unlocks the Speed plugins that
  Phase 1 ships badge-limited at rate 1.0.
- I1 Rewind live audio (OB-4 style): scrub into the past, play from there, catch up to live.
- I3 Retro-record: "save the last N minutes" after the fact.
- I10 Loop grab: mark + loop a chunk, OP-1 style.

HOW TO RUN THE SPEC SESSION
1. FIRST: one Fable xhigh architecture pass producing tasks/specs/<date>-phase2-tape-transport.md.
   Brief it with: the §F seam contract verbatim, the Phase 1 spec for idiom reference, and the
   open questions below. Recommend model+effort lines for every downstream task in the build
   decomposition, same format as Phase 1 (T1..Tn with tiers and gates).
   Run this on: Fable · xhigh — architecture with silent-wrong failure modes (clock math,
   catch-up policy, RT ring safety); a wrong decision here costs a rebuild.
2. The transport UI (scrub bar / tape controls on the app row) is a NOVEL surface — no existing
   FineTune pattern covers it. Per my design-lane rules that means a Fable decision mockup in an
   interview+mockup loop WITH ME before any UI task is cut. Do not let a builder invent it.
3. Spec lands -> STOP and hand it to me for review, exactly like Phase 1. Do not start building.

OPEN QUESTIONS THE SPEC MUST RULE ON (my starting positions in parentheses)
Q1  Ring placement/format: §F pins post-EQ write. Memory: interleaved Float32 stereo at device
    rate? Opt-in per app or always-on with a small default window? (I lean: opt-in, default off,
    per-app toggle in the Effects panel area.)
Q2  Catch-up policy: after rewind/slowdown, how do we return to live — jump, fast-forward at
    >1x until merged, or stay behind until user hits "live"? (I want OB-4 feel: explicit LIVE
    button, no surprise jumps.)
Q3  Clock ownership: transport consumes ring at rate r while HAL demands N frames — who owns
    fractional read position, and how does TimePitch/Varispeed sit relative to the transport
    (transport resamples vs transport feeds the AU at device rate and the AU does the work)?
    §D said Phase 2 makes the transport own the rate — spell out what that means mechanically.
Q4  Interaction with the AU chain during non-live playback: chain renders transport output
    (locked), but what do VU meters, loudness detection, and the soft limiter see? What happens
    to the ring WRITE while reading behind live (keeps recording, obviously — but ruled where)?
Q5  Memory/retention: ring length per app (fixed minutes vs user dial), behaviour at wrap,
    and what Retro-record exports (file format, where it lands, naming).
Q6  Device switch mid-rewind: §2.4 ruled the ring records pre-AutoEQ audio so replays adapt to
    the new device — spec must handle rate mismatch between recorded rate and new device rate.
Q7  What Phase 1 debt blocks Phase 2, if any: the 'Not installed vs failed-to-load' badge split,
    and whether the remaining unrun checklist items (device-switch test 5!) must pass first.
    (I lean: test 5 must be heard before the transport touches the same code paths.)

VERIFICATION BAR (so the spec writes testable gates)
Offline transport harness rendering from a synthetic ring (no live audio needed), same style as
Phase 1's AU harness · clock/position math property-tested · catch-up behaviour deterministic ·
memory bounded and measured · full existing suite (1005 tests) stays green · manual listening
pass at the end with MY ears, checklist handed to me like Phase 1.

Ask me only when a decision changes what ships. The mockup loop for the transport UI is the one
place I expect real back-and-forth.
