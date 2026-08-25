// FineTuneTests/AUChainConfigTests.swift
// Tests for AUPluginConfig / AUChainConfig Codable round-trip, the v12→v13
// migration guarantee, and SettingsManager's absence-vs-empty-plugins semantics.

import Testing
import Foundation
@testable import FineTune

// MARK: - Codable Round-Trip

@Suite("AUPluginConfig / AUChainConfig — JSON serialization")
struct AUChainConfigCodableTests {

    @Test("AUPluginConfig round-trips including a non-nil fullState blob")
    func pluginConfigRoundTrip() throws {
        let original = AUPluginConfig(
            id: UUID(),
            componentType: 1634758764,       // 'aufx'
            componentSubType: 1920298866,    // arbitrary fourCC
            componentManufacturer: 1634758764,
            displayName: "RC-20 Retro Color",
            isBypassed: true,
            fullState: Data([0x01, 0x02, 0x03, 0xFF, 0x00])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AUPluginConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.fullState == Data([0x01, 0x02, 0x03, 0xFF, 0x00]))
    }

    @Test("AUChainConfig round-trips with multiple plugins")
    func chainConfigRoundTrip() throws {
        let plugin1 = AUPluginConfig(
            id: UUID(), componentType: 1, componentSubType: 2, componentManufacturer: 3,
            displayName: "Plugin One", isBypassed: false, fullState: nil
        )
        let plugin2 = AUPluginConfig(
            id: UUID(), componentType: 4, componentSubType: 5, componentManufacturer: 6,
            displayName: "Plugin Two", isBypassed: true, fullState: Data([0x10, 0x20])
        )
        let original = AUChainConfig(plugins: [plugin1, plugin2])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AUChainConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("AUChainConfig with empty plugins round-trips")
    func emptyChainRoundTrip() throws {
        let original = AUChainConfig(plugins: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AUChainConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.plugins.isEmpty)
    }
}

// MARK: - v12 → v13 Migration

@Suite("SettingsManager.Settings — v12 payload decodes to v13 defaults")
@MainActor
struct AUChainMigrationTests {

    @Test("Decoding a realistic v12-shaped payload (no appAUChains/defaultAUChain keys) succeeds with documented defaults")
    func v12PayloadDecodesWithDefaults() throws {
        let json = """
        {
            "version": 12,
            "appVolumes": {"com.test.app": 0.75},
            "appDeviceRouting": {"com.test.app": "device-uid-123"},
            "appMutes": {"com.test.app": false},
            "appBoosts": {"com.test.app": 2.0},
            "appEQSettings": {},
            "systemSoundsFollowsDefault": true,
            "pinnedApps": ["com.test.app"],
            "ignoredApps": [],
            "ddcVolumes": {},
            "ddcMuteStates": {},
            "outputDevicePriority": ["uid-a"],
            "inputDevicePriority": [],
            "hiddenOutputDeviceUIDs": [],
            "hiddenInputDeviceUIDs": [],
            "autoEQPreampEnabled": true,
            "userEQPresets": []
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        // Pre-existing fields still decode correctly.
        #expect(decoded.version == 12)
        #expect(decoded.appVolumes["com.test.app"] == 0.75)

        // New fields are absent from the payload and must decode to the documented defaults.
        #expect(decoded.appAUChains.isEmpty)
        #expect(decoded.defaultAUChain == nil)
    }
}

// MARK: - Absence vs. Empty-Plugins Semantics

@Suite("SettingsManager — AU chain absence vs. empty-plugins semantics")
@MainActor
struct AUChainSemanticsTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("No custom chain: getAUChain returns nil (follows default)")
    func absentChainReturnsNil() {
        let manager = makeManager()
        #expect(manager.getAUChain(for: "com.test.app") == nil)
    }

    @Test("setAUChain with empty plugins yields a non-nil empty chain, distinct from absence")
    func emptyChainIsNotNil() {
        let manager = makeManager()
        manager.setAUChain(AUChainConfig(plugins: []), for: "com.test.app")

        let chain = manager.getAUChain(for: "com.test.app")
        #expect(chain != nil, "An explicitly-set empty chain must not collapse to nil")
        #expect(chain?.plugins.isEmpty == true)
    }

    @Test("clearAUChain removes the key, returning the app to the default chain (nil)")
    func clearReturnsToDefault() {
        let manager = makeManager()
        let plugin = AUPluginConfig(
            id: UUID(), componentType: 1, componentSubType: 2, componentManufacturer: 3,
            displayName: "Test Plugin", isBypassed: false, fullState: nil
        )
        manager.setAUChain(AUChainConfig(plugins: [plugin]), for: "com.test.app")
        #expect(manager.getAUChain(for: "com.test.app") != nil)

        manager.clearAUChain(for: "com.test.app")
        #expect(manager.getAUChain(for: "com.test.app") == nil)
    }

    @Test("defaultAUChain get/set round-trips through SettingsManager")
    func defaultChainRoundTrip() {
        let manager = makeManager()
        #expect(manager.defaultAUChain == nil)

        let plugin = AUPluginConfig(
            id: UUID(), componentType: 7, componentSubType: 8, componentManufacturer: 9,
            displayName: "Default Plugin", isBypassed: false, fullState: nil
        )
        manager.defaultAUChain = AUChainConfig(plugins: [plugin])
        #expect(manager.defaultAUChain?.plugins.first?.displayName == "Default Plugin")

        manager.defaultAUChain = nil
        #expect(manager.defaultAUChain == nil)
    }
}

// MARK: - Prune / Ignore

@Suite("SettingsManager — prune/ignore keep non-empty AU chains, drop empty ones")
@MainActor
struct AUChainPruneIgnoreTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    private func plugin(_ name: String) -> AUPluginConfig {
        AUPluginConfig(
            id: UUID(), componentType: 1, componentSubType: 2, componentManufacturer: 3,
            displayName: name, isBypassed: false, fullState: nil
        )
    }

    @Test("pruneStaleSettings keeps a non-empty chain for an inactive, unpinned app")
    func pruneKeepsNonEmptyChain() {
        let manager = makeManager()
        manager.setAUChain(AUChainConfig(plugins: [plugin("Keeper")]), for: "com.inactive.app")

        manager.pruneStaleSettings(keeping: [])

        #expect(manager.getAUChain(for: "com.inactive.app") != nil)
    }

    @Test("pruneStaleSettings drops an empty chain for an inactive, unpinned app")
    func pruneDropsEmptyChain() {
        let manager = makeManager()
        manager.setAUChain(AUChainConfig(plugins: []), for: "com.inactive.app")

        manager.pruneStaleSettings(keeping: [])

        #expect(manager.getAUChain(for: "com.inactive.app") == nil)
    }

    @Test("ignoreApp keeps a non-empty chain")
    func ignoreKeepsNonEmptyChain() {
        let manager = makeManager()
        manager.setAUChain(AUChainConfig(plugins: [plugin("Keeper")]), for: "com.ignored.app")

        manager.ignoreApp("com.ignored.app", info: IgnoredAppInfo(persistenceIdentifier: "com.ignored.app", displayName: "Ignored", bundleID: nil))

        #expect(manager.getAUChain(for: "com.ignored.app") != nil)
    }

    @Test("ignoreApp drops an empty chain")
    func ignoreDropsEmptyChain() {
        let manager = makeManager()
        manager.setAUChain(AUChainConfig(plugins: []), for: "com.ignored.app")

        manager.ignoreApp("com.ignored.app", info: IgnoredAppInfo(persistenceIdentifier: "com.ignored.app", displayName: "Ignored", bundleID: nil))

        #expect(manager.getAUChain(for: "com.ignored.app") == nil)
    }
}
