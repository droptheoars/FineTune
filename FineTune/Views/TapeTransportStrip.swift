// FineTune/Views/TapeTransportStrip.swift
import SwiftUI

// MARK: - Copy (§8, pinned verbatim)

/// Every user-visible tape-transport string, pasted verbatim from the spec's
/// copy table. Shared by the strip and the Tape panel so neither can drift
/// from the pinned wording independently.
enum TapeTransportCopy {
    static let enableExplainer = "Records this app's audio so you can rewind it. Recording starts now, is kept in memory only, and is never written to disk. Turning the tape off clears it."
    static let lengthCaption = "Longer tapes use more memory. Changing the length clears the tape."
    static let timeSlotTooltipLive = "Tape recorded so far. Drag the bar to rewind."
    static let timeSlotTooltipBehind = "How far behind live you are. Press LIVE to catch up."
    static let endOfTapeLabel = "End of tape"
    static let endOfTapeNotice = "The tape has run out. You are hearing the oldest audio FineTune still has, playing at normal speed. Your speed setting returns when you skip forward or press LIVE."
    static let tapeRestartedLabel = "Tape restarted"
    static let tapeRestartedNotice = "The output device changed its sample rate, so the tape was cleared and recording started over. You are back live."
    static let liveTooltip = "Return to live"
    static let stopTooltip = "Stop the tape (brake)"
    static let playTooltip = "Play"
    static let loopTooltip = "Loop the last 10 seconds"
    static let clearLoopTooltip = "Clear loop"
    static let saveTooltipStrip = "Save the tape as a WAV file"
    static let savePanelRowLabel = "Save tape as WAV"
    static let savePanelButton = "Save"
    static let exportingTooltip = "Saving…"
    static let exportedTooltip = "Saved to Music/FineTune."
    static let exportCaveat = "Saves what the tape recorded: this app's audio with volume and EQ applied. Plugin effects and headphone correction are not included. Files land in Music/FineTune."
    static let speedCaption = "Pitch follows speed, like real tape."
    static let preservePitchCaption = "Keeps the original pitch at any speed. Arrives in a later update."
    static let enableRowLabel = "Tape"
    static let lengthRowLabel = "Tape length"
    static let speedRowLabel = "Speed"
    static let preservePitchRowLabel = "Keep pitch"

    /// Tape-length picker options (§8). Pasted verbatim rather than computed,
    /// so a future formula change can't silently drift from the pinned MB
    /// figures.
    static func lengthOptionLabel(forMinutes minutes: Int) -> String {
        switch minutes {
        case 1: return "1 minute (23 MB)"
        case 5: return "5 minutes (115 MB)"
        case 15: return "15 minutes (346 MB)"
        default: return "\(minutes) minutes"
        }
    }
}

// MARK: - View model (§9)

/// Which loop edge a drag is moving.
enum TapeLoopEdge {
    case start
    case end
}

/// Save-to-WAV progress (§3 item 7, §7 item 6).
enum TapeExportState: Equatable {
    case idle
    case exporting
    case done(until: Date)
}

/// Everything the strip and the Tape panel need for one app: polled state
/// plus one closure per action (§9). Plain data — no manager refs, no RT
/// types. Built at render time by whoever owns the real transport; every
/// mutation happens in a closure that runs after the render, exactly like
/// `AUChainPanelModel`.
struct TapeTransportPanelModel {
    // MARK: State (polled)
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
    var loop: (startBehind: Double, endBehind: Double)?
    var exportState: TapeExportState = .idle
    var preservePitchAvailable: Bool = false // T7 shipped
    var preservePitch: Bool = false

    // MARK: Commands
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
    var onLoopEdgeDrag: (TapeLoopEdge, Double) -> Void = { _, _ in }
    var onLoopEdgeDragEnd: () -> Void = {}
    var onExport: () -> Void = {}
    var onPreservePitchToggle: (Bool) -> Void = { _ in }
}

// MARK: - State → treatment (§5), computed on the plain model so it is
// testable with no view in the loop.

/// Which row of the §5 state table applies. Ordered by precedence: a horizon
/// or cleared-tape notice outranks the ordinary live/behind/stopped read,
/// because both replace the time slot entirely.
enum TapeDisplayState: Equatable {
    case live
    case behind
    case stopped
    case atHorizon
    case clearedNotice
}

/// What the time slot shows, replacing itself with a state label for rows 7–8.
enum TapeTimeSlotContent: Equatable {
    case recordedTime(String)
    case behindTime(String)
    case label(String)
}

enum TapeLabelStyle: Equatable {
    case behind
    case info
}

/// The strip's chip slot: hidden, a rate readout, or the amber "Stopped" chip
/// (which always wins over a rate readout — §3 item 3).
enum TapeChipContent: Equatable {
    case hidden
    case rate(String)
    case stopped
}

/// Whether the strip's LIVE element is an inert label or a real button.
enum TapeLiveElementKind: Equatable {
    case inertLabel
    case button
}

enum TapePrimaryButton: Equatable {
    case stop
    case play
}

extension TapeTransportPanelModel {
    var displayState: TapeDisplayState {
        if atHorizon { return .atHorizon }
        if clearedNoticeActive { return .clearedNotice }
        if isStopped { return .stopped }
        if isLive { return .live }
        return .behind
    }

    var timeSlotContent: TapeTimeSlotContent {
        switch displayState {
        case .atHorizon:
            return .label(TapeTransportCopy.endOfTapeLabel)
        case .clearedNotice:
            return .label(TapeTransportCopy.tapeRestartedLabel)
        case .live:
            return .recordedTime(TapeTransportMath.formatTime(recordedSeconds))
        case .behind, .stopped:
            return .behindTime(TapeTransportMath.formatBehind(secondsBehindLive))
        }
    }

    /// The label style for `.label` content, or `nil` for time-format content.
    var labelStyle: TapeLabelStyle? {
        switch displayState {
        case .atHorizon: return .behind
        case .clearedNotice: return .info
        default: return nil
        }
    }

    var chipContent: TapeChipContent {
        switch displayState {
        case .atHorizon, .clearedNotice, .live:
            return .hidden
        case .stopped:
            return .stopped
        case .behind:
            return rate == 1.0 ? .hidden : .rate(TapeTransportMath.formatRate(rate))
        }
    }

    var liveElementKind: TapeLiveElementKind {
        switch displayState {
        case .live, .clearedNotice: return .inertLabel
        case .behind, .stopped, .atHorizon: return .button
        }
    }

    var primaryButton: TapePrimaryButton {
        isStopped ? .play : .stop
    }

    var isLooping: Bool { loop != nil }
}

// MARK: - Pure math (formatting + scrub/loop geometry), tested without a view

enum TapeTransportMath {
    /// Grab length for the loop button (§6): last N seconds ending at live.
    static let loopGrabSeconds: Double = 10
    /// Minimum loop length; edges cannot be dragged closer than this (§6).
    static let minimumLoopLength: Double = 1
    /// Below this offset, a scrub release snaps to LIVE instead (§6).
    static let snapToLiveThreshold: Double = 0.5
    /// Speed-slider values within this distance of 1.0× snap to it (§7 item 4).
    static let speedSnapTolerance: Double = 0.05

    /// `m:ss`, never hours — the ring never exceeds 15 minutes.
    static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// Behind-live offset, prefixed with U+2212 (minus sign, not a hyphen).
    static func formatBehind(_ seconds: Double) -> String {
        "\u{2212}\(formatTime(seconds))"
    }

    /// Strip speed chip: trims trailing zeros, max 2 decimals (e.g. "0.5×").
    static func formatRate(_ rate: Double) -> String {
        var text = String(format: "%.2f", (rate * 100).rounded() / 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)×"
    }

    /// Tape panel speed readout: always one decimal (e.g. "1.0×").
    static func formatSpeedReadout(_ rate: Double) -> String {
        String(format: "%.1f×", rate)
    }

    /// Converts a horizontal fraction along the scrub track (0 = the oldest
    /// point the ring can ever hold, 1 = live) into seconds behind live,
    /// clamped to what has actually been recorded — dragging past the oldest
    /// recorded audio clamps to that edge, not to ring capacity (§6).
    static func secondsBehindLive(forTrackFraction fraction: Double, capacitySeconds: Double, recordedSeconds: Double) -> Double {
        guard capacitySeconds > 0 else { return 0 }
        let raw = (1 - fraction) * capacitySeconds
        return min(max(raw, 0), max(recordedSeconds, 0))
    }

    /// Inverse: where the thumb sits on the always-full-capacity track for a
    /// given seconds-behind-live value (§4 — the track maps ring capacity,
    /// not recorded length).
    static func trackFraction(forSecondsBehindLive secondsBehind: Double, capacitySeconds: Double) -> Double {
        guard capacitySeconds > 0 else { return 1 }
        return min(max(1 - (secondsBehind / capacitySeconds), 0), 1)
    }

    /// Loop edges after a drag: clamped to the recorded region, minimum
    /// length enforced by pushing the *other* edge, never the one the user
    /// is actively dragging (§6). `start` is further behind live than `end`.
    static func clampedLoopEdges(
        start: Double,
        end: Double,
        draggedEdge: TapeLoopEdge,
        recordedSeconds: Double
    ) -> (startBehind: Double, endBehind: Double) {
        var start = min(max(start, 0), recordedSeconds)
        var end = min(max(end, 0), recordedSeconds)
        switch draggedEdge {
        case .start:
            start = min(max(start, end + minimumLoopLength), recordedSeconds)
        case .end:
            end = max(min(end, start - minimumLoopLength), 0)
        }
        return (startBehind: start, endBehind: end)
    }

    /// Split log mapping so 1.0× always lands at the slider's midpoint: the
    /// lower half (0...0.5) covers 0.25×...1.0×, the upper half covers
    /// 1.0×...2.0×, each logarithmic (§7 item 4).
    static func sliderFraction(forRate rate: Double) -> Double {
        let clamped = min(max(rate, 0.25), 2.0)
        if clamped <= 1.0 {
            return 0.5 * (log(clamped / 0.25) / log(1.0 / 0.25))
        } else {
            return 0.5 + 0.5 * (log(clamped) / log(2.0))
        }
    }

    /// Inverse of `sliderFraction(forRate:)`.
    static func rate(forSliderFraction fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        if clamped <= 0.5 {
            return 0.25 * pow(4.0, clamped / 0.5)
        } else {
            return pow(2.0, (clamped - 0.5) / 0.5)
        }
    }

    /// Applies the ±0.05 detent (§7 item 4).
    static func snappedRate(_ rate: Double) -> Double {
        abs(rate - 1.0) <= speedSnapTolerance ? 1.0 : rate
    }
}

// MARK: - Strip (§3)

/// The always-visible tape transport strip. Lives under the app row header
/// whenever `model.isEnabled` — the caller decides that, this view only
/// renders its contents.
struct TapeTransportStrip: View {
    let model: TapeTransportPanelModel

    /// Wins over `model.secondsBehindLive` while the user is actively
    /// dragging the scrub bar, so every element (time slot, chip, LIVE
    /// element) updates live instead of waiting for the next poll (§9).
    @State private var dragOverrideSecondsBehind: Double?

    private var effectiveModel: TapeTransportPanelModel {
        guard let dragOverrideSecondsBehind else { return model }
        var overridden = model
        overridden.secondsBehindLive = dragOverrideSecondsBehind
        overridden.isLive = dragOverrideSecondsBehind < 0.001
        return overridden
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            TapeScrubBar(model: model, dragOverrideSecondsBehind: $dragOverrideSecondsBehind)
                .frame(minWidth: 180)

            timeSlot
            speedChip
            liveElement
                .animation(DesignTokens.Animation.quick, value: effectiveModel.liveElementKind)
            stopPlayButton
            loopButton
            saveButton
        }
        .frame(height: DesignTokens.Dimensions.tapeStripHeight)
    }

    @ViewBuilder
    private var timeSlot: some View {
        switch effectiveModel.timeSlotContent {
        case .recordedTime(let text):
            Text(text)
                .font(DesignTokens.Typography.percentage)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
                .help(TapeTransportCopy.timeSlotTooltipLive)
        case .behindTime(let text):
            Text(text)
                .font(DesignTokens.Typography.percentage)
                .foregroundStyle(DesignTokens.Colors.tapeBehindText)
                .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
                .help(TapeTransportCopy.timeSlotTooltipBehind)
        case .label(let text):
            let isBehindStyle = effectiveModel.labelStyle == .behind
            Text(text)
                .font(.system(size: 10, weight: isBehindStyle ? .semibold : .medium))
                .foregroundStyle(isBehindStyle ? DesignTokens.Colors.tapeBehindText : DesignTokens.Colors.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .help(isBehindStyle ? TapeTransportCopy.endOfTapeNotice : TapeTransportCopy.tapeRestartedNotice)
        }
    }

    @ViewBuilder
    private var speedChip: some View {
        switch effectiveModel.chipContent {
        case .hidden:
            EmptyView()
        case .rate(let text):
            chipLabel(text, foreground: DesignTokens.Colors.textSecondary, border: DesignTokens.Colors.menuBorder)
        case .stopped:
            chipLabel("Stopped", foreground: DesignTokens.Colors.tapeBehindText, border: DesignTokens.Colors.tapeBehindFill)
        }
    }

    private func chipLabel(_ text: String, foreground: Color, border: Color) -> some View {
        Text(text)
            .font(DesignTokens.Typography.eqLabel)
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(border, lineWidth: 1)
            )
            .fixedSize()
    }

    @ViewBuilder
    private var liveElement: some View {
        switch effectiveModel.liveElementKind {
        case .inertLabel:
            Text("LIVE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize()
        case .button:
            Button(action: model.onLive) {
                Text("LIVE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.Colors.accentPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                            .fill(DesignTokens.Colors.accentPrimary.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                            .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(TapeTransportCopy.liveTooltip)
            .accessibilityLabel(TapeTransportCopy.liveTooltip)
        }
    }

    @ViewBuilder
    private var stopPlayButton: some View {
        switch model.primaryButton {
        case .stop:
            TapeIconButton(systemName: "stop.fill", help: TapeTransportCopy.stopTooltip, action: model.onStopToggle)
        case .play:
            TapeIconButton(systemName: "play.fill", help: TapeTransportCopy.playTooltip, action: model.onStopToggle)
        }
    }

    private var loopButton: some View {
        TapeIconButton(
            systemName: "repeat",
            help: model.isLooping ? TapeTransportCopy.clearLoopTooltip : TapeTransportCopy.loopTooltip,
            tint: model.isLooping ? DesignTokens.Colors.accentPrimary : nil,
            action: model.isLooping ? model.onLoopClear : model.onLoopGrab
        )
    }

    @ViewBuilder
    private var saveButton: some View {
        switch model.exportState {
        case .idle:
            TapeIconButton(systemName: "square.and.arrow.down", help: TapeTransportCopy.saveTooltipStrip, action: model.onExport)
        case .exporting:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
                .help(TapeTransportCopy.exportingTooltip)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.accentPrimary)
                .frame(width: 16, height: 16)
                .help(TapeTransportCopy.exportedTooltip)
        }
    }
}

/// 16×16 icon button, 12pt symbol, `interactiveDefault`/`interactiveHover`
/// (§3). A real `View` (not a free function) so `@State` hover tracking
/// survives across re-renders.
private struct TapeIconButton: View {
    let systemName: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(tint ?? (isHovered ? DesignTokens.Colors.interactiveHover : DesignTokens.Colors.interactiveDefault))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .whenHovered { isHovered = $0 }
    }
}

// MARK: - Scrub bar (§4, §6)

/// Custom `GeometryReader`-drawn scrub bar: track, recorded region, behind
/// gap, loop overlay, live tick, record dot, and playhead thumb, plus the
/// drag gestures for scrubbing and loop-edge dragging.
struct TapeScrubBar: View {
    let model: TapeTransportPanelModel
    @Binding var dragOverrideSecondsBehind: Double?

    /// Wins over `model.loop` while a handle is being dragged.
    @State private var loopEdgeOverride: (startBehind: Double, endBehind: Double)?
    @State private var dragKind: DragKind?

    private enum DragKind {
        case scrub
        case loopEdge(TapeLoopEdge)
    }

    private let rightInset: CGFloat = 8
    private let handleGrabRadius: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let trackWidth = max(geo.size.width - rightInset, 1)
            let effectiveSecondsBehind = dragOverrideSecondsBehind ?? model.secondsBehindLive
            let thumbFraction = TapeTransportMath.trackFraction(forSecondsBehindLive: effectiveSecondsBehind, capacitySeconds: model.capacitySeconds)
            let recordedFraction = model.capacitySeconds > 0 ? min(model.recordedSeconds / model.capacitySeconds, 1) : 0
            let loop = loopEdgeOverride ?? model.loop

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.Colors.tapeTrackEmpty)
                    .frame(width: trackWidth, height: DesignTokens.Dimensions.tapeTrackHeight)

                Capsule()
                    .fill(DesignTokens.Colors.tapeTrackRecorded)
                    .frame(width: trackWidth * recordedFraction, height: DesignTokens.Dimensions.tapeTrackHeight)
                    .offset(x: trackWidth * (1 - recordedFraction))

                if effectiveSecondsBehind > 0.001 {
                    Rectangle()
                        .fill(DesignTokens.Colors.tapeBehindFill)
                        .frame(width: trackWidth * (1 - thumbFraction), height: DesignTokens.Dimensions.tapeTrackHeight)
                        .offset(x: trackWidth * thumbFraction)
                }

                if let loop {
                    let startFraction = TapeTransportMath.trackFraction(forSecondsBehindLive: loop.startBehind, capacitySeconds: model.capacitySeconds)
                    let endFraction = TapeTransportMath.trackFraction(forSecondsBehindLive: loop.endBehind, capacitySeconds: model.capacitySeconds)
                    let lo = min(startFraction, endFraction)
                    let hi = max(startFraction, endFraction)
                    Rectangle()
                        .fill(DesignTokens.Colors.tapeLoopFill)
                        .frame(width: trackWidth * (hi - lo), height: DesignTokens.Dimensions.tapeTrackHeight)
                        .offset(x: trackWidth * lo)

                    loopHandle(atFraction: lo, trackWidth: trackWidth)
                    loopHandle(atFraction: hi, trackWidth: trackWidth)
                }

                Capsule()
                    .fill(DesignTokens.Colors.tapeLiveTick)
                    .frame(width: 2, height: 10)
                    .offset(x: trackWidth - 1)

                Circle()
                    .fill(DesignTokens.Colors.mutedIndicator)
                    .frame(width: 5, height: 5)
                    .offset(x: trackWidth + 4)

                Circle()
                    .fill(DesignTokens.Colors.sliderThumb)
                    .frame(width: DesignTokens.Dimensions.sliderThumbSize, height: DesignTokens.Dimensions.sliderThumbSize)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: trackWidth * thumbFraction - DesignTokens.Dimensions.sliderThumbSize / 2)
                    .animation(DesignTokens.Animation.vuMeterLevel, value: thumbFraction)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(trackWidth: trackWidth, loop: loop))
        }
        .frame(height: DesignTokens.Dimensions.tapeStripHeight)
        .accessibilityElement()
        .accessibilityLabel("Tape position")
        .accessibilityValue(
            model.isLive
                ? "Live"
                : "\(Int(model.secondsBehindLive) / 60) minutes \(Int(model.secondsBehindLive) % 60) seconds behind live"
        )
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 5 : -5
            let next = min(max(model.secondsBehindLive + step, 0), model.recordedSeconds)
            model.onScrub(next)
            model.onScrubEnd()
        }
    }

    private func loopHandle(atFraction fraction: CGFloat, trackWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(DesignTokens.Colors.accentPrimary)
            .frame(width: 3, height: 12)
            .offset(x: trackWidth * fraction - 1.5)
    }

    private func dragGesture(trackWidth: CGFloat, loop: (startBehind: Double, endBehind: Double)?) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let kind = dragKind ?? resolveDragKind(startLocation: value.startLocation, trackWidth: trackWidth, loop: loop)
                dragKind = kind

                let fraction = min(max(value.location.x / trackWidth, 0), 1)
                let seconds = TapeTransportMath.secondsBehindLive(
                    forTrackFraction: Double(fraction),
                    capacitySeconds: model.capacitySeconds,
                    recordedSeconds: model.recordedSeconds
                )

                switch kind {
                case .scrub:
                    dragOverrideSecondsBehind = seconds
                    model.onScrub(seconds)
                case .loopEdge(let edge):
                    var current = loopEdgeOverride ?? loop ?? (startBehind: seconds, endBehind: seconds)
                    switch edge {
                    case .start: current.startBehind = seconds
                    case .end: current.endBehind = seconds
                    }
                    let clamped = TapeTransportMath.clampedLoopEdges(
                        start: current.startBehind,
                        end: current.endBehind,
                        draggedEdge: edge,
                        recordedSeconds: model.recordedSeconds
                    )
                    loopEdgeOverride = clamped
                    model.onLoopEdgeDrag(edge, seconds)
                }
            }
            .onEnded { _ in
                switch dragKind {
                case .scrub:
                    model.onScrubEnd()
                    dragOverrideSecondsBehind = nil
                case .loopEdge:
                    model.onLoopEdgeDragEnd()
                    loopEdgeOverride = nil
                case nil:
                    break
                }
                dragKind = nil
            }
    }

    /// Grabs a loop handle when the drag starts within `handleGrabRadius` of
    /// its center; otherwise it's an ordinary scrub (§6).
    private func resolveDragKind(startLocation: CGPoint, trackWidth: CGFloat, loop: (startBehind: Double, endBehind: Double)?) -> DragKind {
        guard let loop else { return .scrub }
        let startX = trackWidth * TapeTransportMath.trackFraction(forSecondsBehindLive: loop.startBehind, capacitySeconds: model.capacitySeconds)
        let endX = trackWidth * TapeTransportMath.trackFraction(forSecondsBehindLive: loop.endBehind, capacitySeconds: model.capacitySeconds)
        if abs(startLocation.x - startX) <= handleGrabRadius { return .loopEdge(.start) }
        if abs(startLocation.x - endX) <= handleGrabRadius { return .loopEdge(.end) }
        return .scrub
    }
}

// MARK: - Previews (mockup S1–S9)

@MainActor @ViewBuilder
private func previewRow(_ tape: TapeTransportPanelModel, volume: Float = 0.6, level: Float = 0.5) -> some View {
    AppRow(
        app: MockData.sampleApps[0],
        volume: volume,
        audioLevel: level,
        devices: MockData.sampleDevices,
        selectedDeviceUID: MockData.sampleDevices[0].uid,
        onVolumeChange: { _ in },
        onMuteChange: { _ in },
        onDeviceSelected: { _ in },
        tape: tape
    )
}

#Preview("S1 - Tape off") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: false))
    }
}

#Preview("S2 - Live") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 277, isLive: true))
    }
}

#Preview("S3 - Behind live, 1.0x") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 134, isLive: false))
    }
}

#Preview("S4 - Behind live, 0.5x") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 161, isLive: false, rate: 0.5))
    }
}

#Preview("S5 - Stopped") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 182, isLive: false, isStopped: true), level: 0)
    }
}

#Preview("S6 - Looping") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 65, isLive: false, loop: (startBehind: 75, endBehind: 59)))
    }
}

#Preview("S7 - End of tape (E18)") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 300, isLive: false, atHorizon: true))
    }
}

#Preview("S8 - Tape restarted (E22)") {
    PreviewContainer {
        previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 3, secondsBehindLive: 0, isLive: true, clearedNoticeActive: true))
    }
}

#Preview("S9 - Exporting / exported") {
    PreviewContainer {
        VStack(spacing: DesignTokens.Spacing.sm) {
            previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, isLive: true, exportState: .exporting))
            previewRow(TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, isLive: true, exportState: .done(until: Date().addingTimeInterval(3))))
        }
    }
}
