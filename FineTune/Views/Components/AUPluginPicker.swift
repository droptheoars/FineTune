// FineTune/Views/Components/AUPluginPicker.swift
import AudioToolbox
import AVFoundation
import SwiftUI

/// Erik's curated "For listening" picks — the effects he actually reaches for when
/// listening to music through FineTune, plus the two closest neighbours in the same
/// character/saturation family (the rest of the ~40 installed effects are mixing/
/// vocal tools he doesn't use here). Shown pinned above the full alphabetical list.
/// One-line edit: add/remove a row to change the curated set. Matched by
/// (type, subtype, manufacturer) triple; anything not installed is silently skipped.
private let curatedForListening: [(type: UInt32, subType: String, manufacturer: String)] = [
    (kAudioUnitType_Effect, "xaRC", "xlnA"),      // XLN Audio: RC-20 Retro Color
    (kAudioUnitType_Effect, "CtTe", "WsFy"),      // Wavesfactory: Cassette
    (kAudioUnitType_MusicEffect, "FPRr", "FabF"), // FabFilter: Pro-R
    (kAudioUnitType_MusicEffect, "F3Ts", "FabF"), // FabFilter: Timeless 3
    (kAudioUnitType_MusicEffect, "FS2a", "FabF"), // FabFilter: Saturn 2
    (kAudioUnitType_Effect, "XfTT", "XFER"),      // Xfer Records: OTT
]

/// Packs a 4-character AudioComponent code (e.g. "aufx") into its UInt32 form.
private func fourCC(_ code: String) -> UInt32 {
    code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

/// Popover content for adding an Audio Unit to a chain's effect list.
/// See `tasks/specs/2026-08-25-phase1-au-hosting.md` §5.3 — this is the content
/// view only; the caller (the Add row in `AUChainPanelView`) owns the trigger
/// button and the `PopoverHost` presentation, matching `AutoEQSearchPanel`'s
/// role relative to `AutoEQPicker`.
struct AUPluginPicker: View {
    /// Called with the selected component's triple and its display name.
    let onSelect: (AudioComponentDescription, String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var groups: [PickerGroup] = []
    @State private var hasLoaded = false
    @State private var highlightedID: String?
    @State private var hoveredID: String?
    @FocusState private var isSearchFocused: Bool

    private let popoverWidth: CGFloat = 260
    private let listMaxHeight: CGFloat = 320
    private let itemHeight: CGFloat = 26
    private let sectionHeaderHeight: CGFloat = 22

    // MARK: - Row / Group Models

    private struct PickerItem: Identifiable {
        let id: String  // "type-subtype-manufacturer" — stable across relaunches
        let name: String
        let manufacturer: String
        let description: AudioComponentDescription
    }

    private struct PickerGroup: Identifiable {
        let id: String
        let title: String
        let items: [PickerItem]
        let footnote: String?
    }

    private var filteredGroups: [PickerGroup] {
        guard !searchText.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.items.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.manufacturer.localizedCaseInsensitiveContains(searchText)
            }
            guard !matches.isEmpty else { return nil }
            return PickerGroup(id: group.id, title: group.title, items: matches, footnote: group.footnote)
        }
    }

    private var flatItems: [PickerItem] {
        filteredGroups.flatMap(\.items)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()
                .padding(.horizontal, DesignTokens.Spacing.xs)

            resultsList
        }
        .frame(width: popoverWidth)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.return) { activateHighlighted(); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onAppear { isSearchFocused = true }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            groups = await Self.loadGroups()
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textTertiary)

            TextField("Search effects…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .focused($isSearchFocused)
                .accessibilityLabel("Search effects")

            if !searchText.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    searchText = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    // MARK: - Results List

    private var isSearching: Bool { !searchText.isEmpty }

    @ViewBuilder
    private var resultsList: some View {
        if !hasLoaded {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading effects…")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: itemHeight * 4)
        } else if flatItems.isEmpty {
            Text(searchText.isEmpty ? "No effects installed" : "No effects found")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, minHeight: itemHeight * 4)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if isSearching {
                            // Flat results across every group — grouping/footnotes are browse-only.
                            ForEach(flatItems) { item in
                                row(for: item)
                                    .id(item.id)
                            }
                        } else {
                            ForEach(groups) { group in
                                Text(group.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, DesignTokens.Spacing.sm)
                                    .padding(.top, group.id == groups.first?.id ? 2 : 8)
                                    .padding(.bottom, 2)
                                    .frame(height: sectionHeaderHeight, alignment: .bottomLeading)

                                ForEach(group.items) { item in
                                    row(for: item)
                                        .id(item.id)
                                }

                                if let footnote = group.footnote {
                                    Text(footnote)
                                        .font(.system(size: 9))
                                        .foregroundStyle(DesignTokens.Colors.textQuaternary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, DesignTokens.Spacing.sm)
                                        .padding(.top, 2)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xs)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
                .frame(maxHeight: listMaxHeight)
                .onChange(of: highlightedID) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(for item: PickerItem) -> some View {
        let isHighlighted = hoveredID == item.id || highlightedID == item.id

        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                Text(item.manufacturer)
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: itemHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { select(item) }
        .whenHovered { isHovered in
            hoveredID = isHovered ? item.id : nil
            if isHovered { highlightedID = nil }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) by \(item.manufacturer)")
    }

    // MARK: - Selection

    private func select(_ item: PickerItem) {
        onSelect(item.description, item.name)
        onDismiss()
    }

    private func moveHighlight(_ direction: Int) {
        let items = flatItems
        guard !items.isEmpty else { return }
        if let current = highlightedID, let index = items.firstIndex(where: { $0.id == current }) {
            let newIndex = index + direction
            if newIndex >= 0 && newIndex < items.count {
                highlightedID = items[newIndex].id
            }
        } else {
            highlightedID = direction > 0 ? items.first?.id : items.last?.id
        }
        hoveredID = nil
    }

    private func activateHighlighted() {
        guard let highlightedID, let item = flatItems.first(where: { $0.id == highlightedID }) else { return }
        select(item)
    }

    // MARK: - Component Loading

    /// Queries installed effect/musicEffect AUs plus the two Speed converters,
    /// groups them (curated picks first, then Speed, then everything else
    /// alphabetically by manufacturer), and returns off the main actor so a large
    /// plugin catalog doesn't hitch the popover's opening animation.
    private nonisolated static func loadGroups() async -> [PickerGroup] {
        await Task.detached(priority: .userInitiated) {
            let curated = curatedItems()
            let curatedIDs = Set(curated.map(\.id))
            let rest = dedupedItems(from: effectAndMusicEffectComponents())
                .filter { !curatedIDs.contains($0.id) }

            var result: [PickerGroup] = []
            if !curated.isEmpty {
                result.append(PickerGroup(id: "For listening", title: "For listening", items: curated, footnote: nil))
            }
            if let speed = speedGroup() {
                result.append(speed)
            }
            result.append(contentsOf: groupByManufacturer(rest))
            return result
        }.value
    }

    /// Resolves `curatedForListening` against installed components, preserving
    /// Erik's pick order. Entries not installed on this machine are skipped.
    private nonisolated static func curatedItems() -> [PickerItem] {
        let manager = AVAudioUnitComponentManager.shared()
        return curatedForListening.compactMap { pick in
            let desc = AudioComponentDescription(
                componentType: pick.type, componentSubType: fourCC(pick.subType),
                componentManufacturer: fourCC(pick.manufacturer), componentFlags: 0, componentFlagsMask: 0
            )
            guard let component = manager.components(matching: desc).first else { return nil }
            return PickerItem(id: componentID(desc), name: component.name, manufacturer: component.manufacturerName, description: desc)
        }
    }

    private nonisolated static func effectAndMusicEffectComponents() -> [AVAudioUnitComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        // subtype/manufacturer 0 is the standard AudioComponent wildcard — matches any.
        let effect = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0
        )
        let musicEffect = AudioComponentDescription(
            componentType: kAudioUnitType_MusicEffect, componentSubType: 0, componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0
        )
        return manager.components(matching: effect) + manager.components(matching: musicEffect)
    }

    private nonisolated static func dedupedItems(from components: [AVAudioUnitComponent]) -> [PickerItem] {
        // The same plugin installed in both /Library/Audio/Plug-Ins/Components and
        // ~/Library/Audio/Plug-Ins/Components (e.g. Wavesfactory Cassette) is reported
        // as two distinct AVAudioUnitComponent entries sharing one (type, subtype,
        // manufacturer) triple. Dedupe on that triple, keeping the first, so the list
        // doesn't show the plugin twice.
        var seenIDs = Set<String>()
        var items: [PickerItem] = []
        for component in components {
            let id = componentID(component.audioComponentDescription)
            guard seenIDs.insert(id).inserted else { continue }
            items.append(PickerItem(id: id, name: component.name, manufacturer: component.manufacturerName, description: component.audioComponentDescription))
        }
        return items
    }

    private nonisolated static func groupByManufacturer(_ items: [PickerItem]) -> [PickerGroup] {
        let byManufacturer = Dictionary(grouping: items, by: \.manufacturer)
        return byManufacturer.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { manufacturer in
                let sorted = (byManufacturer[manufacturer] ?? [])
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return PickerGroup(id: manufacturer, title: manufacturer, items: sorted, footnote: nil)
            }
    }

    /// Apple TimePitch and Varispeed are format converters (`aufc`), not effects, so
    /// they never come back from the effect-type queries above — look them up by their
    /// exact component descriptions instead (§D).
    private nonisolated static func speedGroup() -> PickerGroup? {
        let manager = AVAudioUnitComponentManager.shared()
        let descriptions = [
            AudioComponentDescription(
                componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_NewTimePitch,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            ),
            AudioComponentDescription(
                componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_Varispeed,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            ),
        ]
        let items: [PickerItem] = descriptions.compactMap { desc in
            guard let component = manager.components(matching: desc).first else { return nil }
            return PickerItem(id: componentID(desc), name: component.name, manufacturer: component.manufacturerName, description: desc)
        }
        guard !items.isEmpty else { return nil }
        return PickerGroup(
            id: "Speed",
            title: "Speed",
            items: items,
            footnote: "Speed plugins work fully in a later update. At speeds other than 1.0, audio will glitch."
        )
    }

    private nonisolated static func componentID(_ description: AudioComponentDescription) -> String {
        "\(description.componentType)-\(description.componentSubType)-\(description.componentManufacturer)"
    }
}

// MARK: - Previews

#Preview("AUPluginPicker") {
    AUPluginPicker(onSelect: { _, _ in }, onDismiss: {})
        .padding()
        .background(Color.black)
}
