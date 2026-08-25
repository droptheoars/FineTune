# Phase 2 — Transport UI Spec (T8)

**Date**: 2026-08-25 · **Author**: Fable (design pass, from the decision mockup) · **Status**: Awaiting Erik's sign-off on the mockup
**Mockup**: `tasks/specs/phase2-transport-mockup.html` — builders match the artifact, do not reinterpret.
**Locked upstream (Erik's interview)**: strip directly under the app row header, visible whenever the tape is enabled, independent of the EQ | Effects toggle · scrub by dragging the bar, no jog buttons · stop = tape brake (~800 ms ramp) and that IS the stop control · loop = grab last N seconds in one action, then drag edges.

All copy below is pinned. Builders paste; they do not write. No em-dashes in any user-visible string; time readouts use the minus sign (U+2212), which is not a dash.

## 1. Files

```
Views/TapeTransportStrip.swift        Strip + scrub bar + subviews                 [new]
Views/TapeTransportPanelView.swift    Tape panel (third segment) + panel model     [new]
Views/Rows/AppRow.swift               Strip under header; third ModeToggle segment [edit]
Views/MenuBarPopupView.swift          Plumb TapeTransportPanelModel + callbacks    [edit]
Views/DesignSystem/DesignTokens.swift New tape tokens (§2)                         [edit]
Views/AUChainPanelView.swift          E28 badge copy swap (§10)                    [edit]
```

`AppPanelMode` (AUChainPanelView.swift:8) gains `case tape`; the `ModeToggle` options in `AppRow` become `[(.eq, "EQ"), (.effects, "Effects"), (.tape, "Tape")]` and its frame widens from 180 to 260.

## 2. New DesignTokens

Follow the `dynamicColor` idiom exactly (unique `name:` per token). Values (light / dark):

| Token | Light | Dark | Used for |
|---|---|---|---|
| `Colors.tapeTrackEmpty` | black 0.06 | white 0.07 | unrecorded ring capacity |
| `Colors.tapeTrackRecorded` | black 0.30 | white 0.30 | recorded tape region |
| `Colors.tapeBehindFill` | rgb(216,160,10) at 0.45 | vuYellow rgb(242,191,51) at 0.45 | gap between playhead and live |
| `Colors.tapeBehindText` | rgb(168,116,0) | vuYellow | offset text, Stopped/End-of-tape labels |
| `Colors.tapeLoopFill` | accent at 0.20 | accent at 0.22 | loop region overlay |
| `Colors.tapeLiveTick` | black 0.45 | white 0.50 | live-edge tick, speed-slider detent |
| `Dimensions.tapeTrackHeight` = 4 | | | scrub track height |
| `Dimensions.tapeStripHeight` = 22 | | | strip content height |

Reused existing tokens: `mutedIndicator` (record dot), `accentPrimary` (LIVE pill, loop handles, active loop button, export check), `sliderThumbSize` = 12 (playhead), `interactiveDefault`/`interactiveHover` (icon buttons), `menuBorder` (speed chip border), `Typography.percentage` (time slot), `Typography.eqLabel` (speed chip), `buttonRadius` (LIVE pill).

## 3. The strip

Lives inside `ExpandableGlassRow`'s `header` VStack region of `AppRow` — concretely: wrap the current header `HStack` in a `VStack(spacing: 0)`; the strip renders under it with `.padding(.top, Spacing.xs)` when `tape.isEnabled`, so it is visible collapsed AND expanded. Strip height `tapeStripHeight` (22). Row card grows from 40 to 66pt when the tape is on. When the tape is enabled the row keeps its at-rest transparent fill rules — the strip does not force the `hoverSurface` fill.

Left to right, `HStack(spacing: Spacing.sm)`:

1. **Scrub bar** — flexible, `minWidth: 180`. Anatomy in §4.
2. **Time slot** — `Typography.percentage`, width 40, right-aligned, fixed (no layout shift). At live: tape recorded so far, `m:ss`, `textTertiary`. Behind: `−m:ss` behind live, `tapeBehindText`. Replaced by the state label (§5 rows 7–8) when one is active.
3. **Speed chip** — `Typography.eqLabel` in a 1px `menuBorder` rounded-4 pill, padding 4×1. Visible only when `rate ≠ 1.0` and not stopped: `0.5×`, `0.75×`, `1.5×` (trim trailing zeros, max 2 decimals). Stopped state shows `Stopped` in `tapeBehindText` with `tapeBehindFill` border instead.
4. **LIVE element** — at live: inert `Text("LIVE")`, 10pt semibold, tracking 0.4, `textSecondary`. Behind: a button, same text in `accentPrimary` on `accentPrimary.opacity(0.15)` fill, 1px `accentPrimary.opacity(0.4)` border, `buttonRadius` corners, padding 7×2. The swap animates with `Animation.quick`.
5. **Stop/Play button** — icon button (16×16 frame, 12pt symbol, `interactiveDefault`, hover `interactiveHover` — the `iconButton` idiom from AUChainPanelView.swift:313). `stop.fill` when `!isStopped`, `play.fill` when `isStopped`. Icon reflects the polled `isStopped`, so it flips when the 800 ms brake actually lands, not on press.
6. **Loop button** — `repeat` symbol, same idiom. Active loop renders it `accentPrimary`.
7. **Save button** — `square.and.arrow.down`, same idiom. During export: `ProgressView` scaled as in the slot-badge spinner (AUChainPanelView.swift:280). For 3 s after success: `checkmark` in `accentPrimary`, then back.

Width proof at 462pt row-inner width: fixed elements ≈ 227pt worst case (time 40 + LIVE 38 + icons 48 + chip 32 + dot 5 + gaps 56), scrub ≥ 235pt. Nothing wraps; do not add elements to the strip.

## 4. Scrub bar anatomy

A `GeometryReader`-drawn custom view, height 22, track vertically centered:

- **Track**: full width minus 8pt right inset (room for the record dot), height `tapeTrackHeight`, radius 2, fill `tapeTrackEmpty`. The track maps the FULL ring capacity: x = 0 is `capacitySeconds` ago, x = right terminus is live, always.
- **Recorded region**: `tapeTrackRecorded`, anchored at the right terminus, width `recordedSeconds / capacitySeconds`. Grows leftward until the ring is full, then covers the track.
- **Behind gap**: `tapeBehindFill` from the playhead to the right terminus, drawn over the recorded region. Zero-width at live.
- **Loop region**: `tapeLoopFill` between the loop edges, drawn over the gap. Edge handles: 3×12pt rounded bars, `accentPrimary`, centered on each edge, extending 4pt above/below the track.
- **Live tick**: 2×10pt rounded bar, `tapeLiveTick`, at the right terminus, centered on the track.
- **Record dot**: 5pt circle, `mutedIndicator`, 4pt right of the terminus, vertically centered. Always visible while the tape is enabled (recording never stops). No pulse animation.
- **Playhead thumb**: 12pt circle (`sliderThumbSize`), `sliderThumb` white with the standard thumb shadow, centered on the current position. Position animates with `Animation.vuMeterLevel` between polls (linear, no spring).

Z-order bottom→top: track, recorded, gap, loop fill, live tick, loop handles, thumb, record dot.

## 5. State → treatment table

| # | State (model predicate) | Track | Time slot | Chip | LIVE | Buttons |
|---|---|---|---|---|---|---|
| 1 | Off (`!isEnabled`) | no strip at all | — | — | — | — |
| 2 | Live (`isLive`) | recorded region, thumb at terminus, no gap | recorded `m:ss` tertiary | hidden | inert label | stop, loop, save |
| 3 | Behind, r = 1 | amber gap thumb→terminus | `−m:ss` amber | hidden | button | stop, loop, save |
| 4 | Behind, r ≠ 1 | as 3 | as 3 | `0.5×` | button | stop, loop, save |
| 5 | Stopped (`isStopped`) | as 3, thumb static | as 3 | `Stopped` amber | button | play, loop, save |
| 6 | Looping (`loop != nil`) | loop overlay + handles | as 3 | per rate | button | stop, loop (accent), save |
| 7 | At horizon (`atHorizon`, E18) | gap covers whole track, thumb at x = 0 | replaced by `End of tape` label (10pt semibold `tapeBehindText`), chip hidden | | button | stop/play, loop, save |
| 8 | Tape cleared notice (`clearedNoticeActive`, E22) | empty track, thumb at terminus | replaced by `Tape restarted` label (10pt medium `textTertiary`) | hidden | inert label | stop, loop, save |
| 9 | Exporting / just exported | per underlying state | per underlying state | | | save shows spinner / checkmark |

The cleared notice (row 8) auto-dismisses after 10 s or on any transport interaction, whichever first. States 7 and 8 keep their full explanation in `.help` tooltips and as a `pcap`-style notice line at the top of the Tape panel while active (copy §8).

## 6. Gestures

- **Scrub drag**: `DragGesture(minimumDistance: 0)` on the whole scrub bar (22pt-tall hit area — not just the 4pt track). On change: clamp x to the recorded region, convert to `secondsBehindLive`, call `onScrub(secondsBehind)`. Fire on every drag change; coalescing is the RT side's job (E27). First movement while live unpins (the model flips `isLive` on the next poll). On end: call `onScrubEnd()`; if the release position is < 0.5 s behind live, the view model issues LIVE instead (snap-to-live). A plain click (no drag) seeks to the clicked position by the same conversion. Dragging left of the oldest recorded audio clamps to the oldest edge.
- **Loop edge drag**: when a loop is active, a drag starting within 10pt of a handle's center grabs that handle instead of scrubbing; call `onLoopEdgeDrag(edge:secondsBehindLive:)` per change. Edges clamp to the recorded region; minimum loop length 1 s; edges cannot cross. Release: `onLoopEdgeDragEnd()`.
- **LIVE press**: `onLive()`. RT runs the 50 ms crossfade; the view just issues the command.
- **Stop/Play press**: `onStopToggle()`. Stop issues targetRate 0 with the 800 ms brake ramp; play restores the Tape panel's speed slider value (which is unchanged by stopping).
- **Loop press**: no loop → `onLoopGrab()`: loop = last 10 s ending at the current live edge, playhead jumps to the loop start, plays at the current rate. Active loop → `onLoopClear()`: loop cleared, playback continues from the current position (no jump).
- **Save press**: `onExport()`. Disabled (0.4 opacity, no hit) while an export is in flight.
- Scrub, loop-edge drag, LIVE, and stop are all available in every enabled state, including while stopped and at the horizon.

## 7. The Tape panel (`TapeTransportPanelView`)

Rendered when `panelMode == .tape`, styled exactly like `AUChainPanelView`'s container: `recessedBackground`, `rowRadius`, padding 12×8, outer padding 2 horizontal / `xs` vertical. Rows are `HStack`s at min-height 26 with 12pt labels; captions are 9pt `textTertiary`, wrapped, under their row.

Top to bottom:

1. **Notice line** (only while E18 or E22 is active): the full-copy notice (§8), 9pt, `tapeBehindText` for E18, `textTertiary` for E22.
2. **`Tape`** + Toggle (`.switch` style, standard size). Caption: the enable explainer (§8). Toggling ON calls `onEnable(ringMinutes)`; the strip appears immediately with an empty track (allocation runs off-main; until `ready` the strip renders state 8's empty-track visual without the notice label). Toggling OFF calls `onDisable()`: strip disappears, tape freed. No confirmation sheet either way.
3. **`Tape length`** + dropdown (menu-style button, `menuBorder`, `buttonRadius`), options and caption §8, current selection shown. Changing it while enabled calls `onRingLengthChange(minutes)` (disable + re-enable semantics; the caption already says it clears). Rows 3–6 render at 0.45 opacity and hit-disabled when the tape is off.
4. **`Speed`** + slider (width `settingsSliderWidth` = 200) + value readout (`Typography.percentage`, width 38, e.g. `1.0×`). Range 0.25–2.0, logarithmic mapping (midpoint = 1.0×), snap to 1.0 when within ±0.05, a `tapeLiveTick` detent tick at the 1.0 position. On change: `onSpeedChange(rate)`. Caption §8. The slider is the requested-rate control; it does not move when E18 forces effective 1.0.
5. **`Keep pitch`** + Toggle. HIDDEN entirely until T7 ships (`preservePitchAvailable`); when available: toggle bound to `preservePitch`, caption §8 first sentence only. (The mockup shows the disabled pre-T7 variant for copy review; the build rule is hidden, not disabled.)
6. **`Save tape as WAV`** + button (`menuBorder` bordered button, `square.and.arrow.down` + `Save`). Caption: the export caveat (§8). Button disabled while exporting or when `recordedSeconds == 0`.

## 8. Pinned copy

| Where | Copy |
|---|---|
| Enable explainer (panel, under Tape switch) | `Records this app's audio so you can rewind it. Recording starts now, is kept in memory only, and is never written to disk. Turning the tape off clears it.` |
| Tape length options | `1 minute (23 MB)` · `5 minutes (115 MB)` · `15 minutes (346 MB)` |
| Tape length caption | `Longer tapes use more memory. Changing the length clears the tape.` |
| Time slot tooltip, live | `Tape recorded so far. Drag the bar to rewind.` |
| Time slot tooltip, behind | `How far behind live you are. Press LIVE to catch up.` |
| E18 strip label | `End of tape` |
| E18 tooltip + panel notice | `The tape has run out. You are hearing the oldest audio FineTune still has, playing at normal speed. Your speed setting returns when you skip forward or press LIVE.` |
| E22 strip label | `Tape restarted` |
| E22 tooltip + panel notice | `The output device changed its sample rate, so the tape was cleared and recording started over. You are back live.` |
| LIVE tooltip | `Return to live` |
| Stop tooltip / stopped | `Stop the tape (brake)` / `Play` |
| Loop tooltip / looping | `Loop the last 10 seconds` / `Clear loop` |
| Save tooltip (strip) / panel row label / panel button | `Save the tape as a WAV file` / `Save tape as WAV` / `Save` |
| Export progress / success tooltip | `Saving…` / `Saved to Music/FineTune.` |
| Export caveat caption (panel, under Save) | `Saves what the tape recorded: this app's audio with volume and EQ applied. Plugin effects and headphone correction are not included. Files land in Music/FineTune.` |
| Speed caption | `Pitch follows speed, like real tape.` |
| Keep pitch caption (T7) | `Keeps the original pitch at any speed. Arrives in a later update.` |
| E28 badge tooltip (§10) | `This plugin changes playback speed and will glitch. Use the tape instead: turn it on for this app and set the speed on its Tape panel.` |

Time format: `m:ss` (never hours; max ring is 15 min). Behind readout prefixed with U+2212. File success confirmation is primarily the Finder reveal (already ruled §3-Q5); the tooltip string above is the in-popup echo.

## 9. View model + update cadence

One plain struct, built at render time in `MenuBarPopupView` (the `AUChainPanelModel` pattern — plain data + closures, no manager refs, mutations routed through closures that run after render):

```swift
struct TapeTransportPanelModel {
    // state (polled)
    var isEnabled: Bool = false
    var ringMinutes: Int = 5
    var capacitySeconds: Double = 300
    var recordedSeconds: Double = 0
    var secondsBehindLive: Double = 0        // 0 == live
    var isLive: Bool = true
    var rate: Double = 1.0                   // requested rate (panel slider value)
    var isStopped: Bool = false              // effective rate reached 0
    var atHorizon: Bool = false              // E18
    var clearedNoticeActive: Bool = false    // E22, view-side 10 s auto-dismiss
    var loop: (startBehind: Double, endBehind: Double)? = nil
    var exportState: ExportState = .idle     // .idle / .exporting / .done(until: Date)
    var preservePitchAvailable: Bool = false // T7 shipped
    var preservePitch: Bool = false

    // commands
    var onEnable: (Int) -> Void = { _ in }
    var onDisable: () -> Void = {}
    var onRingLengthChange: (Int) -> Void = { _ in }
    var onScrub: (Double) -> Void = { _ in } // seconds behind live
    var onScrubEnd: () -> Void = {}
    var onLive: () -> Void = {}
    var onStopToggle: () -> Void = {}
    var onSpeedChange: (Double) -> Void = { _ in }
    var onLoopGrab: () -> Void = {}
    var onLoopClear: () -> Void = {}
    var onLoopEdgeDrag: (LoopEdge, Double) -> Void = { _, _ in }
    var onLoopEdgeDragEnd: () -> Void = {}
    var onExport: () -> Void = {}
    var onPreservePitchToggle: (Bool) -> Void = { _ in }
}
```

State fields come from `TapeTransportManager` polling the RT diagnostics (`diagnosticsSnapshot` pattern) on a 10 Hz MainActor timer that runs only while the popup is open and at least one transport is enabled — same lifecycle discipline as the VU polling in `AppRowWithLevelPolling`. The playhead is NOT animated between polls beyond `Animation.vuMeterLevel`; while the user is dragging, the local drag position wins over the polled position (the `useRef`-style local-override idiom: a `@State` drag override cleared on `onScrubEnd`).

## 10. E28 badge copy swap

`AUChainPanelView.swift:288` — replace the `.rateMismatch` `.help` string with the E28 copy from §8. `AUPluginPicker`'s `Speed` group is removed in T7, not here; this spec touches only the badge string.

## 11. Accessibility + keyboard

- Scrub bar: `.accessibilityElement()`, label `Tape position`, value `Live` or `N minutes M seconds behind live`, `.accessibilityAdjustableAction` stepping 5 s per increment/decrement.
- LIVE, stop/play, loop, save: standard buttons with their tooltip strings as `accessibilityLabel` (the `iconButton` idiom already does this).
- Loop handles: not separately focusable in v1; loop edges are adjustable by pointer only (stated limitation, revisit if requested).
- The strip adds nothing to the popup's key loop beyond its buttons; Escape/expand behavior of the row is unchanged. The row's expand button continues to toggle the panel area; the strip does not intercept row hover.

## 12. What the builder does not decide

Everything above is ruled: token names and values, metrics, state treatments, gesture thresholds (0.5 s snap-to-live, 10pt handle grab, 1 s min loop, 10 s grab length, 10 s notice dismissal, 3 s export check), copy, formats, and the model surface. The only tolerances left open are SwiftUI-mechanical: exact `GeometryReader` plumbing, hit-testing implementation, and preview fixtures (previews must cover every row of the §5 table, matching the mockup panel for panel).
