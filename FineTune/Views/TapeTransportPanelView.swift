// FineTune/Views/TapeTransportPanelView.swift
import SwiftUI

/// The Tape panel: the third `AppPanelMode` segment, holding every deliberate
/// tape control that didn't fit on the always-visible strip (§7). Styled
/// exactly like `AUChainPanelView`'s container.
struct TapeTransportPanelView: View {
    let model: TapeTransportPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if let notice {
                Text(notice.text)
                    .font(.system(size: 9))
                    .foregroundStyle(notice.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            enableRow
            caption(TapeTransportCopy.enableExplainer)

            Group {
                lengthRow
                caption(TapeTransportCopy.lengthCaption)

                speedRow
                caption(TapeTransportCopy.speedCaption)

                if model.preservePitchAvailable {
                    preservePitchRow
                    caption(TapeTransportCopy.preservePitchCaption)
                }

                saveRow
                caption(TapeTransportCopy.exportCaveat)
            }
            .opacity(model.isEnabled ? 1 : 0.45)
            .allowsHitTesting(model.isEnabled)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Notice (E18 / E22, §5 rows 7–8, §7 item 1)

    private var notice: (text: String, color: Color)? {
        if model.atHorizon {
            return (TapeTransportCopy.endOfTapeNotice, DesignTokens.Colors.tapeBehindText)
        }
        if model.clearedNoticeActive {
            return (TapeTransportCopy.tapeRestartedNotice, DesignTokens.Colors.textTertiary)
        }
        return nil
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Rows

    private var enableRow: some View {
        HStack {
            Text(TapeTransportCopy.enableRowLabel)
                .font(.system(size: 12))
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.isEnabled },
                set: { $0 ? model.onEnable(model.ringMinutes) : model.onDisable() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .frame(minHeight: 26)
    }

    private var lengthRow: some View {
        HStack {
            Text(TapeTransportCopy.lengthRowLabel)
                .font(.system(size: 12))
            Spacer()
            Menu {
                ForEach(TapeTransportConfig.allowedRingMinutes, id: \.self) { minutes in
                    Button(TapeTransportCopy.lengthOptionLabel(forMinutes: minutes)) {
                        model.onRingLengthChange(minutes)
                    }
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text(TapeTransportCopy.lengthOptionLabel(forMinutes: model.ringMinutes))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                        .strokeBorder(DesignTokens.Colors.menuBorder, lineWidth: 1)
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .frame(minHeight: 26)
    }

    private var speedRow: some View {
        HStack {
            Text(TapeTransportCopy.speedRowLabel)
                .font(.system(size: 12))
            Spacer()
            TapeSpeedSlider(rate: model.rate, onChange: model.onSpeedChange)
            Text(TapeTransportMath.formatSpeedReadout(model.rate))
                .font(DesignTokens.Typography.percentage)
                .frame(width: 38, alignment: .trailing)
        }
        .frame(minHeight: 26)
    }

    private var preservePitchRow: some View {
        HStack {
            Text(TapeTransportCopy.preservePitchRowLabel)
                .font(.system(size: 12))
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.preservePitch },
                set: { model.onPreservePitchToggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .frame(minHeight: 26)
    }

    private var saveRow: some View {
        let disabled = model.exportState != .idle || model.recordedSeconds <= 0
        return HStack {
            Text(TapeTransportCopy.savePanelRowLabel)
                .font(.system(size: 12))
            Spacer()
            Button(action: model.onExport) {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    saveButtonIcon
                    Text(TapeTransportCopy.savePanelButton)
                }
                .font(.system(size: 11))
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                        .strokeBorder(DesignTokens.Colors.menuBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
        }
        .frame(minHeight: 26)
    }

    @ViewBuilder
    private var saveButtonIcon: some View {
        switch model.exportState {
        case .exporting:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark")
        case .idle:
            Image(systemName: "square.and.arrow.down")
        }
    }
}

/// Requested-rate slider: 0.25×–2.0× on a split-log scale so 1.0× always
/// sits at the midpoint, with a `tapeLiveTick`-colored detent there (§7
/// item 4). Wraps the existing minimal-track slider rather than building a
/// new one; only the detent tick is bespoke.
private struct TapeSpeedSlider: View {
    let rate: Double
    let onChange: (Double) -> Void

    private var fractionBinding: Binding<Double> {
        Binding(
            get: { TapeTransportMath.sliderFraction(forRate: rate) },
            set: { onChange(TapeTransportMath.snappedRate(TapeTransportMath.rate(forSliderFraction: $0))) }
        )
    }

    var body: some View {
        LiquidGlassSlider(value: fractionBinding, in: 0...1, showUnityMarker: false)
            .overlay {
                Rectangle()
                    .fill(DesignTokens.Colors.tapeLiveTick)
                    .frame(width: 1, height: 8)
                    .allowsHitTesting(false)
            }
            .frame(width: DesignTokens.Dimensions.settingsSliderWidth)
    }
}

// MARK: - Previews (mockup S10)

#Preview("Tape Panel - Off") {
    PreviewContainer {
        TapeTransportPanelView(model: TapeTransportPanelModel(isEnabled: false))
    }
}

#Preview("Tape Panel - Behind live") {
    PreviewContainer {
        TapeTransportPanelView(model: TapeTransportPanelModel(
            isEnabled: true,
            ringMinutes: 5,
            recordedSeconds: 300,
            secondsBehindLive: 134,
            isLive: false
        ))
    }
}

#Preview("Tape Panel - Keep pitch available") {
    PreviewContainer {
        TapeTransportPanelView(model: TapeTransportPanelModel(
            isEnabled: true,
            ringMinutes: 15,
            recordedSeconds: 900,
            rate: 0.75,
            preservePitchAvailable: true,
            preservePitch: true
        ))
    }
}

#Preview("Tape Panel - End of tape notice") {
    PreviewContainer {
        TapeTransportPanelView(model: TapeTransportPanelModel(
            isEnabled: true,
            recordedSeconds: 300,
            secondsBehindLive: 300,
            isLive: false,
            atHorizon: true
        ))
    }
}
