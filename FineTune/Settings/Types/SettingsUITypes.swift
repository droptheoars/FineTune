// FineTune/Settings/Types/SettingsUITypes.swift
import Foundation
import AppKit

// MARK: - App-Wide Settings Enums

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default` = "Default"
    case speaker = "Speaker"
    case device = "Device"
    case waveform = "Waveform"
    case equalizer = "Equalizer"

    var id: String { rawValue }

    /// The icon name - either asset catalog name or SF Symbol
    var iconName: String {
        switch self {
        case .default: return "MenuBarIcon"
        case .speaker: return "speaker.wave.2.fill"
        case .device: return "headphones"
        case .waveform: return "waveform"
        case .equalizer: return "slider.vertical.3"
        }
    }

    /// Whether this uses an SF Symbol (vs asset catalog image)
    var isSystemSymbol: Bool {
        self != .default
    }
}

// MARK: - HUD Style

/// Style of the on-screen HUD shown when media keys drive FineTune's volume.
/// `.tahoe` renders a small top-right pill; `.classic` renders a center-bottom panel
/// with 16 segment tiles matching Apple's pre-Tahoe HUD aesthetic.
enum HUDStyle: String, Codable, CaseIterable, Identifiable {
    case tahoe
    case classic

    var id: String { rawValue }
}

// MARK: - Appearance Preference

/// User preference for app appearance. `.system` follows macOS appearance live;
/// `.light` and `.dark` lock the override regardless of system setting.
enum AppearancePreference: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case system
    case light
    case dark

    var id: String { rawValue }

    var description: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

extension AppearancePreference {
    /// AppKit appearance override. `nil` means "inherit from window or app".
    /// Apply via `nsView.window?.appearance = value` for any `NSWindow`/`NSPanel`
    /// the app hosts (popup, popover, HUD).
    /// `.aqua` available since macOS 10.9; `.darkAqua` since 10.14.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Menu Bar Popup Size

enum MenuBarPopupSize: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var description: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }
}

// MARK: - Tape Save Length

/// Global (not per-app) preference for how much of a tape a save captures.
/// Independent of ring length (`TapeTransportConfig.ringMinutes`): the ring is
/// how much the app remembers, this is how much a save habitually keeps.
enum TapeSaveLength: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case seconds30
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes
    case wholeTape

    var id: String { rawValue }

    /// Minutes to request from `AppTapeTransport.export(lastMinutes:)`.
    /// `nil` for `.wholeTape` — the caller substitutes the ring's own length,
    /// which `export` then clamps to what is actually recorded either way.
    var minutes: Double? {
        switch self {
        case .seconds30: return 30.0 / 60.0
        case .oneMinute: return 1
        case .twoMinutes: return 2
        case .fiveMinutes: return 5
        case .fifteenMinutes: return 15
        case .wholeTape: return nil
        }
    }

    var description: String {
        switch self {
        case .seconds30: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .twoMinutes: return "2 minutes"
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .wholeTape: return "Whole tape"
        }
    }
}

struct PopupDimensions: Equatable {
    let width: CGFloat
    let contentPadding: CGFloat
    /// Ceiling on the scrollable body. Sized to stay within a 13" MacBook Air's
    /// usable height after the menu bar, since FluidMenuBarExtra does not clamp
    /// the popup against `screen.visibleFrame` vertically.
    let maxContentHeight: CGFloat
}

extension MenuBarPopupSize {
    var dimensions: PopupDimensions {
        switch self {
        case .compact:
            return PopupDimensions(
                width: 470,
                contentPadding: 12,
                maxContentHeight: 560
            )
        case .comfortable:
            return PopupDimensions(
                width: 510,
                contentPadding: 16,
                maxContentHeight: 660
            )
        case .spacious:
            return PopupDimensions(
                width: 560,
                contentPadding: 20,
                maxContentHeight: 760
            )
        }
    }
}

// MARK: - Volume Hotkey Step Size

enum VolumeHotkeyStep: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case coarse
    case normal
    case fine
    case extraFine

    var id: String { rawValue }

    var sliderDelta: Double {
        switch self {
        case .coarse:    return 1.0 / 8.0
        case .normal:    return 1.0 / 16.0
        case .fine:      return 1.0 / 32.0
        case .extraFine: return 1.0 / 64.0
        }
    }

    var description: String {
        switch self {
        case .coarse:    return "Coarse (12.5%)"
        case .normal:    return "Normal (6.25%)"
        case .fine:      return "Fine (3.13%)"
        case .extraFine: return "Extra-Fine (1.56%)"
        }
    }
}
