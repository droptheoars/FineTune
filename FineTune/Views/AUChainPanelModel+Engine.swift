// FineTune/Views/AUChainPanelModel+Engine.swift
import AudioToolbox
import Foundation

// MARK: - Manufacturer lookup

/// `AUPluginConfig` persists only the component triple (spec §4), so a row's
/// manufacturer line has to come from the component registry. Cached because the
/// panel model is rebuilt on every popup render; a lookup that finds nothing
/// (plugin uninstalled) caches the empty string too — reinstalling is already a
/// relaunch-to-revive path (§E).
@MainActor
enum AUManufacturerNames {
    private static var cache: [String: String] = [:]

    static func name(for description: AudioComponentDescription) -> String {
        let key = "\(description.componentType)-\(description.componentSubType)-\(description.componentManufacturer)"
        if let cached = cache[key] { return cached }

        var lookup = description
        var resolved = ""
        // Registry metadata only — this never instantiates the plugin.
        if let component = AudioComponentFindNext(nil, &lookup) {
            var copied: Unmanaged<CFString>?
            if AudioComponentCopyName(component, &copied) == noErr,
               let full = copied?.takeRetainedValue() as String? {
                // AudioComponentCopyName returns "Manufacturer: Plugin Name".
                let prefix = full.components(separatedBy: ": ").first ?? ""
                resolved = prefix == full ? "" : prefix
            }
        }
        cache[key] = resolved
        return resolved
    }
}

// MARK: - Panel model

extension MenuBarPopupView {

    /// The Effects panel's view state for one app, with every callback wired to a
    /// real chain mutation (spec §5.2; fork semantics §4).
    ///
    /// **Propagation**: `AUChainManager` and `AppAUChain` are `@Observable`, and
    /// every read below happens while `body` is evaluating — so slot lifecycle
    /// changes, badge flips and latency updates re-run the body and rebuild this
    /// struct. Nothing polls.
    ///
    /// **Read-only on purpose**: creating a chain mutates the manager, which must
    /// not happen during view evaluation. The lookup here is `chain(for:)`; every
    /// mutation goes through `editableAUChain(for:appName:)` inside a closure,
    /// which runs after the render.
    func auChainModel(for persistenceID: String, appName: String) -> AUChainPanelModel {
        let engine = audioEngine
        let manager = engine.auChainManager
        let chain = manager.chain(for: persistenceID)
        // Absence of a key means "follows the default chain" (§4).
        let followsDefault = chain?.followsDefault ?? (engine.settingsManager.getAUChain(for: persistenceID) == nil)

        return AUChainPanelModel(
            isDefaultChain: followsDefault,
            slots: chain.map(Self.slotViewStates) ?? Self.configuredSlotViewStates(
                engine.settingsManager.getAUChain(for: persistenceID)?.plugins ?? manager.defaultChain.plugins
            ),
            totalLatencySamples: chain?.totalLatencySamples ?? 0,
            sampleRate: chain.flatMap(\.sampleRate) ?? 48_000,
            onAdd: { description, name in
                engine.editableAUChain(for: persistenceID, appName: appName).addPlugin(
                    AUPluginConfig(
                        id: UUID(),
                        componentType: description.componentType,
                        componentSubType: description.componentSubType,
                        componentManufacturer: description.componentManufacturer,
                        displayName: name,
                        isBypassed: false,
                        fullState: nil
                    )
                )
            },
            onRemove: { slotID in
                engine.editableAUChain(for: persistenceID, appName: appName).removePlugin(id: slotID)
            },
            onToggleBypass: { slotID in
                let chain = engine.editableAUChain(for: persistenceID, appName: appName)
                guard let slot = chain.slots.first(where: { $0.id == slotID }) else { return }
                chain.setBypassed(!slot.config.isBypassed, id: slotID)
            },
            onReorder: { slotID, toIndex in
                let chain = engine.editableAUChain(for: persistenceID, appName: appName)
                guard let from = chain.slots.firstIndex(where: { $0.id == slotID }) else { return }
                // `move(fromOffsets:toOffset:)` takes a pre-removal insertion
                // index, so a downward move needs one more than the target slot.
                chain.move(
                    fromOffsets: IndexSet(integer: from),
                    toOffset: from < toIndex ? toIndex + 1 : toIndex
                )
            },
            onOpenWindow: { slotID in
                engine.editableAUChain(for: persistenceID, appName: appName).openWindow(id: slotID)
            },
            onUseDefaultChain: {
                engine.resetAUChainToDefault(for: persistenceID)
            },
            onRemoveAll: {
                // On an app that follows the default this menu item edits the
                // DEFAULT chain itself (§5.2 item 1) — it is the one structural
                // edit that does not fork. Every other edit forks (§4).
                if followsDefault {
                    manager.setDefaultChain(AUChainConfig(plugins: []))
                } else {
                    engine.editableAUChain(for: persistenceID, appName: appName).removeAll()
                }
            }
        )
    }

    private static func slotViewStates(_ chain: AppAUChain) -> [AUSlotViewState] {
        chain.slots.map { slot in
            AUSlotViewState(
                id: slot.id,
                displayName: slot.config.displayName,
                manufacturer: AUManufacturerNames.name(for: slot.config.componentDescription),
                isBypassed: slot.config.isBypassed,
                status: status(of: slot)
            )
        }
    }

    /// An app with no live chain (pinned-inactive, or an app whose tap never
    /// needed one) still shows its persisted configuration. Nothing is
    /// instantiated until a tap attaches, so no lifecycle badge is shown.
    private static func configuredSlotViewStates(_ plugins: [AUPluginConfig]) -> [AUSlotViewState] {
        plugins.map { config in
            AUSlotViewState(
                id: config.id,
                displayName: config.displayName,
                manufacturer: AUManufacturerNames.name(for: config.componentDescription),
                isBypassed: config.isBypassed,
                status: .ready
            )
        }
    }

    /// Lifecycle + diagnostics state → the pinned badge set (§5.2).
    private static func status(of slot: AppAUChain.Slot) -> AUSlotStatus {
        // The invalid-audio latch outranks everything: the slot is out of the
        // render plan, so no other diagnostic can still be accruing.
        if slot.isAutoBypassedForNaN { return .nanDisabled }
        switch slot.state {
        case .instantiating, .configuring, .allocating:
            return .instantiating
        case .failed(.missing):
            return .missing
        case .failed(.formatRefused), .failed(.allocFailed), .failed(.hung), .failed(.stateRestore):
            // §5.2 pins badges only for "not installed", "not responding",
            // restore-failed, invalid audio and speed. A plugin that is present
            // but refused its format or failed to allocate did not come up:
            // "Not responding" is the pinned copy that fits without claiming the
            // plugin is absent.
            return .hung
        case .ready:
            if slot.showsSpeedBadge { return .rateMismatch }
            return slot.stateRestoreFailed ? .stateRestoreFailed : .ready
        case .empty:
            // Configured but not yet brought up — same as an unbuilt chain.
            return .ready
        }
    }
}
