import Foundation

/// Persisted per-app tape transport configuration.
/// See `tasks/specs/2026-08-25-phase2-tape-transport.md` §3-I for the schema this mirrors.
struct TapeTransportConfig: Codable, Equatable {
    /// Allowed ring lengths, in minutes. `ringMinutes` always clamps to the nearest of these.
    static let allowedRingMinutes = [1, 5, 15]

    var isEnabled: Bool = false
    var ringMinutes: Int = 5          // 1 | 5 | 15, clamped on decode
    var preservePitch: Bool = false   // T7; ignored until built

    init(isEnabled: Bool = false, ringMinutes: Int = 5, preservePitch: Bool = false) {
        self.isEnabled = isEnabled
        self.ringMinutes = Self.clampRingMinutes(ringMinutes)
        self.preservePitch = preservePitch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let decodedRingMinutes = try c.decodeIfPresent(Int.self, forKey: .ringMinutes) ?? 5
        ringMinutes = Self.clampRingMinutes(decodedRingMinutes)
        preservePitch = try c.decodeIfPresent(Bool.self, forKey: .preservePitch) ?? false
    }

    /// Snaps a (possibly garbage or out-of-range) value to the nearest allowed ring length,
    /// so a corrupt settings file can never produce an oversized ring allocation.
    private static func clampRingMinutes(_ value: Int) -> Int {
        allowedRingMinutes.min(by: { abs($0 - value) < abs($1 - value) }) ?? 5
    }
}
