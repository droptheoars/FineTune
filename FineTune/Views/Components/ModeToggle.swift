// FineTune/Views/Components/ModeToggle.swift
import SwiftUI

/// A segmented control over any set of modes. `ModeToggle(mode:)` keeps the
/// device single/multi call sites unchanged; other surfaces (the EQ / Effects
/// switch in the expanded app row) pass their own options.
struct ModeToggle<Mode: Hashable>: View {
    @Binding var mode: Mode
    let options: [(mode: Mode, label: String)]

    @State private var hoveredOption: Mode?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.mode) { option in
                optionButton(option.mode, label: option.label)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func optionButton(_ optionMode: Mode, label: String) -> some View {
        let isSelected = mode == optionMode
        let isHovered = hoveredOption == optionMode

        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                mode = optionMode
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)

                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs + 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius - 1)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? DesignTokens.Colors.hoverSurface : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .whenHovered { hovering in
            withAnimation(DesignTokens.Animation.hover) {
                hoveredOption = hovering ? optionMode : nil
            }
        }
    }
}

extension ModeToggle where Mode == DeviceSelectionMode {
    init(mode: Binding<DeviceSelectionMode>) {
        self.init(mode: mode, options: [(.single, "Single"), (.multi, "Multi")])
    }
}

// MARK: - Previews

#Preview("Mode Toggle - Single Selected") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ModeToggle(mode: .constant(.single))
            ModeToggle(mode: .constant(.multi))
        }
        .frame(width: 180)
    }
}

#Preview("Mode Toggle Interactive") {
    struct InteractivePreview: View {
        @State private var mode: DeviceSelectionMode = .single

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    ModeToggle(mode: $mode)
                        .frame(width: 180)

                    Text("Current: \(mode == .single ? "Single" : "Multi")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
