// FineTune/Views/AUChainPanelView.swift
import AudioToolbox
import SwiftUI

// MARK: - View state

/// Which panel the expanded app row is showing (§5.1).
enum AppPanelMode: Hashable {
    case eq
    case effects
}

/// Lifecycle/health of one plugin slot, as far as the UI cares (§2.5, §E).
enum AUSlotStatus: Equatable {
    case instantiating
    case ready
    case missing
    case stateRestoreFailed
    case hung
    case nanDisabled
    case rateMismatch
}

/// One plugin row's view state. Plain data — no audio types, no manager refs.
struct AUSlotViewState: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var manufacturer: String
    var isBypassed: Bool
    var status: AUSlotStatus
}

/// Everything `AUChainPanelView` needs: chain-level state plus one closure per
/// action. `AppAUChain`/`AUChainManager` (T3/T8) populate it; the view stays dumb
/// and fully previewable.
struct AUChainPanelModel {
    var isDefaultChain: Bool = true
    var slots: [AUSlotViewState] = []
    var totalLatencySamples: Int = 0
    /// Needed to render `totalLatencySamples` as milliseconds in the header.
    var sampleRate: Double = 48_000

    var onAdd: (AudioComponentDescription, String) -> Void = { _, _ in }
    var onRemove: (UUID) -> Void = { _ in }
    var onToggleBypass: (UUID) -> Void = { _ in }
    /// `slotID` should end up at `toIndex` in the current `slots` order.
    var onReorder: (_ slotID: UUID, _ toIndex: Int) -> Void = { _, _ in }
    var onOpenWindow: (UUID) -> Void = { _ in }
    var onUseDefaultChain: () -> Void = {}
    var onRemoveAll: () -> Void = {}
    /// Writes this app's chain into the default chain. The only way to build the
    /// default from the UI — without it the default is write-only.
    var onSaveAsDefault: () -> Void = {}
}

// MARK: - Panel

/// The Effects panel inside an expanded app row (spec §5.2). All copy pinned.
struct AUChainPanelView: View {
    let model: AUChainPanelModel

    @State private var showForkNote = false
    @State private var isPickerPresented = false
    @State private var hoveredSlotID: UUID?

    @Environment(\.appearancePreference) private var appearancePreference

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header

            if showForkNote {
                Text("This app now has its own chain. The default chain no longer applies here.")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.slots.isEmpty {
                Text("No effects. Audio passes through unchanged.")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            } else {
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    ForEach(model.slots) { slot in
                        slotRow(slot)
                    }
                }
            }

            addRow
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

    // MARK: - Header

    private var header: some View {
        ZStack {
            latencyLabel

            HStack(spacing: 0) {
                Text(model.isDefaultChain ? "Default chain" : "Custom chain")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                Spacer()

                overflowMenu
            }
        }
    }

    /// `totalLatencySamples` rendered in milliseconds (§E).
    private var latencyMilliseconds: Int {
        let ms = Double(model.totalLatencySamples) / max(model.sampleRate, 1) * 1000
        return Int(ms.rounded())
    }

    @ViewBuilder
    private var latencyLabel: some View {
        if model.totalLatencySamples > 0 {
            let ms = latencyMilliseconds
            HStack(spacing: DesignTokens.Spacing.xxs) {
                if ms >= 20 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Text("≈ \(ms) ms")
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .font(.system(size: 9))
            .help(ms >= 20 ? "This chain delays audio by about \(ms) ms. Video lip-sync may drift." : "")
        }
    }

    private var overflowMenu: some View {
        Menu {
            if !model.isDefaultChain {
                Button("Use Default Chain") { model.onUseDefaultChain() }
                Button("Save as Default Chain") { model.onSaveAsDefault() }
            }
            // Forks like every other structural edit (§4): on a default-following
            // app this gives THIS app an explicitly-empty chain and leaves every
            // other app's default alone. `Use Default Chain` is the undo.
            Button("Remove All Effects") {
                structuralEdit { model.onRemoveAll() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Plugin row

    private func slotRow(_ slot: AUSlotViewState) -> some View {
        let isHovered = hoveredSlotID == slot.id

        return HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(slot.displayName)
                    .font(DesignTokens.Typography.rowName)
                    .lineLimit(1)
                if !slot.manufacturer.isEmpty {
                    Text(slot.manufacturer)
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.xs)

            badge(for: slot.status)

            iconButton("power", help: slot.isBypassed ? "Enable" : "Bypass") {
                structuralEdit { model.onToggleBypass(slot.id) }
            }
            iconButton("macwindow", help: "Open plugin window") {
                model.onOpenWindow(slot.id)
            }
            iconButton("xmark", help: "Remove") {
                structuralEdit { model.onRemove(slot.id) }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .opacity(slot.isBypassed ? 0.5 : 1)
        .contentShape(Rectangle())
        .whenHovered { hovering in
            hoveredSlotID = hovering ? slot.id : (hoveredSlotID == slot.id ? nil : hoveredSlotID)
        }
        .draggable(slot.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = items.first,
                  let draggedID = UUID(uuidString: dropped),
                  draggedID != slot.id,
                  let toIndex = model.slots.firstIndex(where: { $0.id == slot.id })
            else { return false }
            structuralEdit { model.onReorder(draggedID, toIndex) }
            return true
        }
    }

    @ViewBuilder
    private func badge(for status: AUSlotStatus) -> some View {
        switch status {
        case .ready:
            EmptyView()
        case .instantiating:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: DesignTokens.Dimensions.iconSizeSmall)
        case .missing:
            badgeLabel(icon: "exclamationmark.triangle", text: "Not installed")
        case .stateRestoreFailed:
            badgeLabel(icon: nil, text: "Settings couldn't be restored")
        case .hung:
            badgeLabel(icon: nil, text: "Not responding")
        case .nanDisabled:
            badgeLabel(icon: nil, text: "Disabled: produced invalid audio")
        case .rateMismatch:
            Image(systemName: "speedometer")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .help("This plugin changes playback speed. Full speed control arrives with the recorder (Phase 2); at other speeds audio will glitch.")
        }
    }

    private func badgeLabel(icon: String?, text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            if let icon {
                Image(systemName: icon)
            }
            Text(text)
        }
        .font(.system(size: 9))
        .foregroundStyle(DesignTokens.Colors.textTertiary)
        .lineLimit(1)
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(width: DesignTokens.Dimensions.iconSizeSmall, height: DesignTokens.Dimensions.iconSizeSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Add row

    private var addRow: some View {
        Button {
            isPickerPresented.toggle()
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                Text("Add Effect")
                    .font(DesignTokens.Typography.pickerText)
            }
            .foregroundStyle(DesignTokens.Colors.interactiveDefault)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            PopoverHost(
                isPresented: $isPickerPresented,
                preferredColorScheme: appearancePreference.swiftUIColorScheme,
                nsAppearance: appearancePreference.nsAppearance
            ) {
                AUPluginPicker(
                    onSelect: { description, name in
                        isPickerPresented = false
                        structuralEdit { model.onAdd(description, name) }
                    },
                    onDismiss: { isPickerPresented = false }
                )
            }
        )
    }

    // MARK: - Fork rule (§5.2 item 5)

    /// Runs a structural edit. The first one made while the app is still on the
    /// default chain silently forks, so the panel shows the one-time note. The
    /// note lives in `@State`, and `ExpandableGlassRow` drops `expandedContent`
    /// on collapse — so it auto-dismisses on the next expand.
    private func structuralEdit(_ edit: () -> Void) {
        if model.isDefaultChain {
            showForkNote = true
        }
        edit()
    }
}

// MARK: - Previews

private func previewSlot(
    _ name: String,
    _ manufacturer: String = "Wavesfactory",
    bypassed: Bool = false,
    status: AUSlotStatus = .ready
) -> AUSlotViewState {
    AUSlotViewState(
        id: UUID(),
        displayName: name,
        manufacturer: manufacturer,
        isBypassed: bypassed,
        status: status
    )
}

#Preview("Effects Panel - Empty") {
    PreviewContainer {
        AUChainPanelView(model: AUChainPanelModel())
    }
}

#Preview("Effects Panel - Healthy Chain") {
    PreviewContainer {
        AUChainPanelView(
            model: AUChainPanelModel(
                isDefaultChain: false,
                slots: [
                    previewSlot("RC-20 Retro Color", "XLN Audio"),
                    previewSlot("Cassette", "Wavesfactory", bypassed: true),
                    previewSlot("AUDelay", "Apple")
                ],
                totalLatencySamples: 576
            )
        )
    }
}

#Preview("Effects Panel - Badge States") {
    PreviewContainer {
        AUChainPanelView(
            model: AUChainPanelModel(
                isDefaultChain: false,
                slots: [
                    previewSlot("Loading Plugin", "Acme", status: .instantiating),
                    previewSlot("Healthy Plugin", "Acme", status: .ready),
                    previewSlot("Missing Plugin", "Acme", status: .missing),
                    previewSlot("Restore Failed", "Acme", status: .stateRestoreFailed),
                    previewSlot("Wedged Plugin", "Acme", status: .hung),
                    previewSlot("Bad Audio", "Acme", status: .nanDisabled),
                    previewSlot("TimePitch", "Apple", status: .rateMismatch)
                ]
            )
        )
    }
}

#Preview("Effects Panel - Latency Warning") {
    PreviewContainer {
        AUChainPanelView(
            model: AUChainPanelModel(
                isDefaultChain: false,
                slots: [previewSlot("Linear Phase EQ", "Acme")],
                totalLatencySamples: 2048
            )
        )
    }
}

#Preview("Effects Panel - Fork Note") {
    struct ForkPreview: View {
        @State private var isDefault = true
        @State private var slots = [previewSlot("RC-20 Retro Color", "XLN Audio")]

        var body: some View {
            PreviewContainer {
                AUChainPanelView(
                    model: AUChainPanelModel(
                        isDefaultChain: isDefault,
                        slots: slots,
                        onRemove: { id in
                            isDefault = false
                            slots.removeAll { $0.id == id }
                        },
                        onToggleBypass: { _ in isDefault = false }
                    )
                )
            }
        }
    }
    return ForkPreview()
}
