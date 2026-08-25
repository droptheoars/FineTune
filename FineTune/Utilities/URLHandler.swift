// FineTune/Utilities/URLHandler.swift
import Foundation
import os

/// Protocol for the AudioEngine surface that URLHandler depends on.
/// Extracted for testability (allows mock injection).
@MainActor
protocol URLHandlerEngine {
    var apps: [AudioApp] { get }
    var settingsManager: SettingsManager { get }
    func setVolume(for app: AudioApp, to volume: Float)
    func getVolume(for app: AudioApp) -> Float
    func setMute(for app: AudioApp, to muted: Bool)
    func getMute(for app: AudioApp) -> Bool
    func setDevice(for app: AudioApp, deviceUID: String?)
    func setVolumeForInactive(identifier: String, to volume: Float)
    func setMuteForInactive(identifier: String, to muted: Bool)
    func getMuteForInactive(identifier: String) -> Bool
    func editableTapeTransport(for identifier: String, appName: String) -> AppTapeTransport
}

/// Handles URL scheme actions for FineTune (finetune://...)
@MainActor
final class URLHandler {
    private let audioEngine: any URLHandlerEngine
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "URLHandler")

    init(audioEngine: any URLHandlerEngine) {
        self.audioEngine = audioEngine
    }
    
    func handleURL(_ url: URL) {
        logger.info("Received URL: \(url.absoluteString)")
        
        guard url.scheme == "finetune" else {
            logger.warning("Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }
        
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = components?.host
        let queryItems = components?.queryItems ?? []
      
        switch host {
        // Volume actions
        case "set-volumes":
            handleSetVolumes(queryItems: queryItems)
        case "step-volume":
            handleStepVolume(queryItems: queryItems)
        // Mute actions
        case "set-mute":
            handleSetMute(queryItems: queryItems)
        case "toggle-mute":
            handleToggleMute(queryItems: queryItems)
        // Other actions
        case "set-device":
            handleSetDevice(queryItems: queryItems)
        case "reset":
            handleReset(queryItems: queryItems)
        case "tape":
            handleTape(queryItems: queryItems)
        default:
            logger.warning("Unknown URL action: \(host ?? "nil")")
        }
    }
    
    // MARK: - Volume Actions

    /// Set volumes for one or more apps
    /// URL format: finetune://set-volumes?app=com.a&volume=100&app=com.b&volume=50
    /// Volume is percentage: 0-100 (gain only, boost is per-app and set separately)
    private func handleSetVolumes(queryItems: [URLQueryItem]) {
        var pairs: [(identifier: String, volume: Int)] = []
        var currentApp: String?

        // Parse app/volume pairs in order
        for item in queryItems {
            switch item.name.lowercased() {
            case "app":
                currentApp = item.value
            case "volume":
                guard let app = currentApp else {
                    logger.warning("set-volumes: volume parameter without preceding app")
                    continue
                }
                guard let volumeStr = item.value,
                      let volume = Int(volumeStr),
                      (0...100).contains(volume) else {
                    logger.warning("set-volumes: invalid volume '\(item.value ?? "nil")' for app \(app) (valid range: 0-100)")
                    currentApp = nil
                    continue
                }
                pairs.append((app, volume))
                currentApp = nil
            default:
                continue
            }
        }

        // Warn about trailing app without volume
        if let trailing = currentApp {
            logger.warning("set-volumes: trailing app '\(trailing)' without volume parameter")
        }

        guard !pairs.isEmpty else {
            logger.error("set-volumes: No valid app/volume pairs found")
            return
        }

        for (identifier, volumePercent) in pairs {
            // Linear conversion: volume=100 → gain 1.0
            let gain = Float(volumePercent) / 100.0

            if let app = findApp(by: identifier) {
                audioEngine.setVolume(for: app, to: gain)
                logger.info("Set volume for \(app.name) to \(volumePercent)%")
            } else {
                // App not active - persist for when it launches
                audioEngine.setVolumeForInactive(identifier: identifier, to: gain)
                logger.info("Set volume for inactive app \(identifier) to \(volumePercent)%")
            }
        }
    }

    /// Step volume up or down for an app
    /// URL format: finetune://step-volume?app=com.a&direction=up (or down)
    /// Steps by 5% slider position
    private func handleStepVolume(queryItems: [URLQueryItem]) {
        guard let appIdentifier = queryItems.first(where: { $0.name == "app" })?.value else {
            logger.error("step-volume: missing app parameter")
            return
        }

        guard let direction = queryItems.first(where: { $0.name == "direction" })?.value else {
            logger.error("step-volume: missing direction parameter (use 'up' or 'down')")
            return
        }

        guard let app = findApp(by: appIdentifier) else {
            logger.warning("step-volume: app not found '\(appIdentifier)'")
            return
        }

        let currentGain = audioEngine.getVolume(for: app)
        let stepAmount: Double = 0.05 // 5% slider position
        var sliderPosition = VolumeMapping.gainToSlider(currentGain)

        switch direction.lowercased() {
        case "up", "+":
            sliderPosition = min(1.0, sliderPosition + stepAmount)
        case "down", "-":
            sliderPosition = max(0.0, sliderPosition - stepAmount)
        default:
            logger.error("step-volume: invalid direction '\(direction)'. Use 'up' or 'down'")
            return
        }

        let newGain = VolumeMapping.sliderToGain(sliderPosition)
        audioEngine.setVolume(for: app, to: newGain)
        let newPercent = Int(round(newGain * 100))
        logger.info("Stepped volume \(direction) for \(app.name) to \(newPercent)%")
    }

    // MARK: - Mute Actions

    /// Set mute state for one or more apps
    /// URL format: finetune://set-mute?app=com.a&muted=true&app=com.b&muted=false
    private func handleSetMute(queryItems: [URLQueryItem]) {
        var pairs: [(identifier: String, muted: Bool)] = []
        var currentApp: String?

        for item in queryItems {
            switch item.name.lowercased() {
            case "app":
                currentApp = item.value
            case "muted":
                guard let app = currentApp else {
                    logger.warning("set-mute: muted parameter without preceding app")
                    continue
                }
                guard let mutedStr = item.value,
                      let muted = parseBool(mutedStr) else {
                    logger.warning("set-mute: invalid muted value '\(item.value ?? "nil")' for app \(app)")
                    currentApp = nil
                    continue
                }
                pairs.append((app, muted))
                currentApp = nil
            default:
                continue
            }
        }

        // Warn about trailing app without muted value
        if let trailing = currentApp {
            logger.warning("set-mute: trailing app '\(trailing)' without muted parameter")
        }

        guard !pairs.isEmpty else {
            logger.error("set-mute: No valid app/muted pairs found")
            return
        }

        for (identifier, muted) in pairs {
            if let app = findApp(by: identifier) {
                audioEngine.setMute(for: app, to: muted)
                logger.info("Set mute for \(app.name) to \(muted)")
            } else {
                audioEngine.setMuteForInactive(identifier: identifier, to: muted)
                logger.info("Set mute for inactive app \(identifier) to \(muted)")
            }
        }
    }

    /// Toggle mute state for apps
    /// URL format: finetune://toggle-mute?app=com.a&app=com.b
    private func handleToggleMute(queryItems: [URLQueryItem]) {
        let identifiers = queryItems
            .filter { $0.name.lowercased() == "app" }
            .compactMap { $0.value }

        guard !identifiers.isEmpty else {
            logger.error("toggle-mute: No app identifiers provided")
            return
        }

        for identifier in identifiers {
            if let app = findApp(by: identifier) {
                let current = audioEngine.getMute(for: app)
                audioEngine.setMute(for: app, to: !current)
                logger.info("Toggled mute for \(app.name) to \(!current)")
            } else {
                let current = audioEngine.getMuteForInactive(identifier: identifier)
                audioEngine.setMuteForInactive(identifier: identifier, to: !current)
                logger.info("Toggled mute for inactive app \(identifier) to \(!current)")
            }
        }
    }

    // MARK: - Other Actions

    /// Set output device for an app
    /// URL format: finetune://set-device?app=com.a&device=<deviceUID>
    private func handleSetDevice(queryItems: [URLQueryItem]) {
        guard let appIdentifier = queryItems.first(where: { $0.name == "app" })?.value else {
            logger.error("set-device: missing app parameter")
            return
        }

        guard let deviceUID = queryItems.first(where: { $0.name == "device" })?.value else {
            logger.error("set-device: missing device parameter")
            return
        }

        guard let app = findApp(by: appIdentifier) else {
            logger.warning("set-device: app not found '\(appIdentifier)'")
            return
        }

        audioEngine.setDevice(for: app, deviceUID: deviceUID)
        logger.info("Routed \(app.name) to device \(deviceUID)")
    }

    /// Reset apps to 100% volume and unmute
    /// URL format: finetune://reset?app=com.a&app=com.b or finetune://reset (all apps)
    private func handleReset(queryItems: [URLQueryItem]) {
        let identifiers = queryItems
            .filter { $0.name.lowercased() == "app" }
            .compactMap { $0.value }

        if identifiers.isEmpty {
            // Reset all active apps to 100% and unmute
            let apps = audioEngine.apps
            for app in apps {
                audioEngine.setVolume(for: app, to: 1.0)
                audioEngine.setMute(for: app, to: false)
            }
            logger.info("Reset all \(apps.count) apps to 100% (unmuted)")
        } else {
            for identifier in identifiers {
                if let app = findApp(by: identifier) {
                    audioEngine.setVolume(for: app, to: 1.0)
                    audioEngine.setMute(for: app, to: false)
                    logger.info("Reset \(app.name) to 100% (unmuted)")
                } else {
                    audioEngine.setVolumeForInactive(identifier: identifier, to: 1.0)
                    audioEngine.setMuteForInactive(identifier: identifier, to: false)
                    logger.info("Reset inactive app \(identifier) to 100% (unmuted)")
                }
            }
        }
    }

    // MARK: - Tape Transport (debug surface)

    /// Drive an app's tape transport by hand. This is the interim control surface for
    /// Phase 2 (spec §5) until the transport UI exists, and the vehicle for hearing
    /// rewind early.
    ///
    /// URL format: `finetune://tape?app=com.spotify.client&<one or more controls>`
    ///   `enable=true|false`  arm/disarm the tape (recording starts when armed)
    ///   `rewind=<seconds>`   play from N seconds behind live
    ///   `rate=<-4…4>`        tape speed; 0 = stopped (pitch follows speed)
    ///   `ramp=<seconds>`     optional rate ramp for this change (default 0.02; try 0.8 for a brake)
    ///   `live=1`             return to live through the 50 ms crossfade
    ///   `export=<minutes>`   retro-record the last N minutes (needs T6's exporter)
    ///   `status=1`           log the transport diagnostics
    ///
    /// Controls apply in that order. Arming allocates the ring off-main, so `enable=true`
    /// and `rewind` in the SAME URL will not both take effect — send them separately.
    private func handleTape(queryItems: [URLQueryItem]) {
        guard let identifier = queryItems.first(where: { $0.name.lowercased() == "app" })?.value else {
            logger.error("tape: missing app parameter")
            return
        }
        let appName = findApp(by: identifier)?.name ?? identifier
        let owner = audioEngine.editableTapeTransport(for: identifier, appName: appName)

        if let raw = tapeValue("enable", in: queryItems) {
            guard let enabled = parseBool(raw) else {
                logger.error("tape: invalid enable value '\(raw)'")
                return
            }
            owner.setEnabled(enabled)
            logger.info("tape: \(enabled ? "armed" : "disarmed") for \(identifier)")
        }

        guard let rt = owner.transport else {
            if queryItems.contains(where: { $0.name.lowercased() != "app" && $0.name.lowercased() != "enable" }) {
                logger.warning("tape: no ring for \(identifier) yet — arm it first, then re-send")
            }
            return
        }

        if let raw = tapeValue("rewind", in: queryItems) {
            guard let seconds = Double(raw), seconds >= 0 else {
                logger.error("tape: invalid rewind value '\(raw)'")
                return
            }
            let target = rt.writtenFrames - Int64((seconds * rt.sampleRate).rounded())
            rt.requestSeek(toFrame: max(0, target))
            logger.info("tape: seek \(seconds, format: .fixed(precision: 2))s behind live for \(identifier)")
        }

        if let raw = tapeValue("rate", in: queryItems) {
            guard let rate = Float(raw) else {
                logger.error("tape: invalid rate value '\(raw)'")
                return
            }
            let ramp = tapeValue("ramp", in: queryItems).flatMap(Double.init)
                ?? TapeTransportRT.defaultRampSeconds
            rt.setTargetRate(rate, rampSeconds: ramp)
            logger.info("tape: rate \(rate) over \(ramp, format: .fixed(precision: 3))s for \(identifier)")
        }

        if let raw = tapeValue("live", in: queryItems), parseBool(raw) == true {
            rt.requestLive()
            logger.info("tape: LIVE for \(identifier)")
        }

        if let raw = tapeValue("export", in: queryItems) {
            guard let minutes = Double(raw), minutes > 0 else {
                logger.error("tape: invalid export value '\(raw)'")
                return
            }
            let started = owner.export(lastMinutes: minutes)
            logger.info("tape: export of \(minutes, format: .fixed(precision: 2))min \(started ? "started" : "unavailable")")
        }

        if let raw = tapeValue("status", in: queryItems), parseBool(raw) == true {
            let d = rt.diagnosticsSnapshot()
            logger.info("""
                tape status \(identifier): live=\(d.isPinnedToLive) lag=\(d.lagFrames) \
                written=\(d.writeFrames) horizon=\(d.isAtHorizon) loopDegraded=\(d.isLoopDegraded) \
                clamps=\(d.clampEventCount) seeks=\(d.seeksConsumed) peak=\(d.lastOutputPeak)
                """)
        }
    }

    private func tapeValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems.first { $0.name.lowercased() == name }?.value
    }

    // MARK: - Helpers

    /// Find an app by bundle ID or persistence identifier
    private func findApp(by identifier: String) -> AudioApp? {
        audioEngine.apps.first { $0.persistenceIdentifier == identifier }
    }

    /// Parse boolean from string (supports true/false, 1/0, yes/no)
    private func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}
