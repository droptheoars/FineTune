// FineTuneTests/TapeTransportConfigTests.swift
// Tests for TapeTransportConfig Codable round-trip, the v13→v14 settings
// migration guarantee, the version-stamp-on-encode fix, ringMinutes clamping,
// and SettingsManager's enabled-config-is-user-intent semantics.

import Testing
import Foundation
@testable import FineTune

// MARK: - Codable Round-Trip

@Suite("TapeTransportConfig — JSON serialization")
struct TapeTransportConfigCodableTests {

    @Test("TapeTransportConfig round-trips")
    func roundTrip() throws {
        let original = TapeTransportConfig(isEnabled: true, ringMinutes: 15, preservePitch: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TapeTransportConfig.self, from: data)
        #expect(decoded == original)
    }

    @Test("Default TapeTransportConfig round-trips")
    func defaultRoundTrip() throws {
        let original = TapeTransportConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TapeTransportConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.isEnabled == false)
        #expect(decoded.ringMinutes == 5)
        #expect(decoded.preservePitch == false)
    }

    @Test("ringMinutes clamps to the nearest allowed value on decode", arguments: [
        (0, 1), (3, 1), (7, 5), (99, 15), (-1, 1),
    ])
    func ringMinutesClamps(input: Int, expected: Int) throws {
        let json = """
        {"isEnabled": false, "ringMinutes": \(input), "preservePitch": false}
        """
        let decoded = try JSONDecoder().decode(TapeTransportConfig.self, from: Data(json.utf8))
        #expect(TapeTransportConfig.allowedRingMinutes.contains(decoded.ringMinutes))
        #expect(decoded.ringMinutes == expected)
    }

    @Test("The memberwise initializer also clamps ringMinutes")
    func memberwiseInitClamps() {
        #expect(TapeTransportConfig(ringMinutes: 0).ringMinutes == 1)
        #expect(TapeTransportConfig(ringMinutes: 99).ringMinutes == 15)
    }
}

// MARK: - v13 → v14 Migration

@Suite("SettingsManager.Settings — v13 payload decodes to v14 defaults")
@MainActor
struct TapeTransportMigrationTests {

    @Test("Decoding a v13-shaped payload (no appTapeTransport key) succeeds with an empty dictionary")
    func v13PayloadDecodesWithDefaults() throws {
        let json = """
        {
            "version": 13,
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
            "userEQPresets": [],
            "appAUChains": {}
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

        // Pre-existing fields still decode correctly.
        #expect(decoded.appVolumes["com.test.app"] == 0.75)

        // The new field is absent from the payload and must decode to an empty dictionary.
        #expect(decoded.appTapeTransport.isEmpty)
    }

    @Test("A v12 payload decodes without error and re-encodes stamped as version 14")
    func v12PayloadReencodesAsV14() throws {
        let json = """
        {
            "version": 12,
            "appVolumes": {},
            "appDeviceRouting": {},
            "appMutes": {},
            "appBoosts": {},
            "appEQSettings": {},
            "systemSoundsFollowsDefault": true,
            "pinnedApps": [],
            "ignoredApps": [],
            "ddcVolumes": {},
            "ddcMuteStates": {},
            "outputDevicePriority": [],
            "inputDevicePriority": [],
            "hiddenOutputDeviceUIDs": [],
            "hiddenInputDeviceUIDs": [],
            "autoEQPreampEnabled": true,
            "userEQPresets": []
        }
        """
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))

        let reencoded = try JSONEncoder().encode(decoded)
        let reparsed = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(reparsed?["version"] as? Int == 14)
    }
}

// MARK: - SettingsManager Accessors

@Suite("SettingsManager — tape transport accessors")
@MainActor
struct TapeTransportAccessorTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("No custom config: getTapeTransport returns nil (off by default)")
    func absentConfigReturnsNil() {
        let manager = makeManager()
        #expect(manager.getTapeTransport(for: "com.test.app") == nil)
    }

    @Test("setTapeTransport / getTapeTransport round-trip through SettingsManager")
    func roundTripThroughManager() {
        let manager = makeManager()
        let config = TapeTransportConfig(isEnabled: true, ringMinutes: 1, preservePitch: false)
        manager.setTapeTransport(config, for: "com.test.app")
        #expect(manager.getTapeTransport(for: "com.test.app") == config)
    }

    @Test("clearTapeTransport removes the key, returning the app to the default (off) state")
    func clearReturnsToDefault() {
        let manager = makeManager()
        manager.setTapeTransport(TapeTransportConfig(isEnabled: true), for: "com.test.app")
        #expect(manager.getTapeTransport(for: "com.test.app") != nil)

        manager.clearTapeTransport(for: "com.test.app")
        #expect(manager.getTapeTransport(for: "com.test.app") == nil)
    }
}

// MARK: - Prune / Ignore

@Suite("SettingsManager — prune/ignore keep an enabled tape transport, drop a disabled one")
@MainActor
struct TapeTransportPruneIgnoreTests {

    private func makeManager() -> SettingsManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return SettingsManager(directory: tempDir)
    }

    @Test("pruneStaleSettings keeps an enabled config for an inactive, unpinned app")
    func pruneKeepsEnabledConfig() {
        let manager = makeManager()
        manager.setTapeTransport(TapeTransportConfig(isEnabled: true), for: "com.inactive.app")

        manager.pruneStaleSettings(keeping: [])

        #expect(manager.getTapeTransport(for: "com.inactive.app") != nil)
    }

    @Test("pruneStaleSettings drops a disabled (default) config for an inactive, unpinned app")
    func pruneDropsDisabledConfig() {
        let manager = makeManager()
        manager.setTapeTransport(TapeTransportConfig(isEnabled: false), for: "com.inactive.app")

        manager.pruneStaleSettings(keeping: [])

        #expect(manager.getTapeTransport(for: "com.inactive.app") == nil)
    }

    @Test("ignoreApp keeps an enabled config")
    func ignoreKeepsEnabledConfig() {
        let manager = makeManager()
        manager.setTapeTransport(TapeTransportConfig(isEnabled: true), for: "com.ignored.app")

        manager.ignoreApp("com.ignored.app", info: IgnoredAppInfo(persistenceIdentifier: "com.ignored.app", displayName: "Ignored", bundleID: nil))

        #expect(manager.getTapeTransport(for: "com.ignored.app") != nil)
    }

    @Test("ignoreApp drops a disabled (default) config")
    func ignoreDropsDisabledConfig() {
        let manager = makeManager()
        manager.setTapeTransport(TapeTransportConfig(isEnabled: false), for: "com.ignored.app")

        manager.ignoreApp("com.ignored.app", info: IgnoredAppInfo(persistenceIdentifier: "com.ignored.app", displayName: "Ignored", bundleID: nil))

        #expect(manager.getTapeTransport(for: "com.ignored.app") == nil)
    }
}
