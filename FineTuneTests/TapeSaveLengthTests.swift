// FineTuneTests/TapeSaveLengthTests.swift
// T12: the global "Save length" preference for tape exports. Codable round-trip
// and default-on-missing-key follow the same pattern as MenuBarPopupSizeTests;
// the clamping behaviour this setting drives lives in AppTapeTransportTests,
// against the real `export(lastMinutes:)` seam.

import Testing
import Foundation
@testable import FineTune

@Suite("TapeSaveLength — Codable round-trip")
struct TapeSaveLengthCodableTests {

    @Test("All cases round-trip through JSON as their raw String value")
    func roundTripAllCases() throws {
        for length in TapeSaveLength.allCases {
            let data = try JSONEncoder().encode(length)
            let decoded = try JSONDecoder().decode(TapeSaveLength.self, from: data)
            #expect(decoded == length)
        }
    }

    // Defaulting to .wholeTape means an existing settings.json keeps saving the
    // whole tape after this update, matching today's behaviour exactly.
    @Test("AppSettings.tapeSaveLength defaults to .wholeTape when the key is missing")
    func defaultMissingKey() throws {
        let data = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.tapeSaveLength == .wholeTape)
    }

    @Test("AppSettings.tapeSaveLength round-trips through full JSON")
    func roundTripThroughAppSettings() throws {
        var settings = AppSettings()
        settings.tapeSaveLength = .fiveMinutes

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.tapeSaveLength == .fiveMinutes)
    }
}

@Suite("TapeSaveLength — minutes mapping")
struct TapeSaveLengthMinutesTests {

    @Test("Fixed lengths map to their minute value", arguments: [
        (TapeSaveLength.seconds30, 0.5), (.oneMinute, 1), (.twoMinutes, 2),
        (.fiveMinutes, 5), (.fifteenMinutes, 15),
    ])
    func fixedLengthsMapToMinutes(length: TapeSaveLength, expected: Double) {
        #expect(length.minutes == expected)
    }

    @Test("Whole tape has no fixed minute value — the caller substitutes the ring length")
    func wholeTapeHasNoFixedMinutes() {
        #expect(TapeSaveLength.wholeTape.minutes == nil)
    }
}
