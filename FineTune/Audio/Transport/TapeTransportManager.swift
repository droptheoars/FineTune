// FineTune/Audio/Transport/TapeTransportManager.swift
import Foundation

/// Registry of `identifier → AppTapeTransport` (spec §2.6), mirroring
/// `AUChainManager`'s shape. The two layers are deliberately independent: this
/// manager knows nothing about AU chains and `AUChainManager` grows zero
/// transport concerns (§2.1).
///
/// Transports are created lazily. A tape is opt-in and off by default (§3-Q1),
/// so an app only gets one when its persisted config says enabled — or when the
/// UI asks for an editable transport in order to arm it.
@Observable
@MainActor
final class TapeTransportManager {

    private let settingsManager: SettingsManager
    private let makeRT: @Sendable (Double, Int) -> TapeTransportRT
    private let graceWait: @Sendable () -> Void

    private var transports: [String: AppTapeTransport] = [:]
    private var appNames: [String: String] = [:]

    /// T6 seam, forwarded to every transport this manager owns (§2.6 export).
    var onExport: (@MainActor (TapeTransportRT, Int64, Int, String) async -> Bool)? {
        didSet {
            for transport in transports.values { transport.onExport = onExport }
        }
    }

    init(
        settingsManager: SettingsManager,
        makeRT: @escaping @Sendable (Double, Int) -> TapeTransportRT = {
            TapeTransportRT(sampleRate: $0, capacityFrames: $1)
        },
        graceWait: @escaping @Sendable () -> Void = {
            Thread.sleep(forTimeInterval: AppTapeTransport.releaseGracePeriod)
        }
    ) {
        self.settingsManager = settingsManager
        self.makeRT = makeRT
        self.graceWait = graceWait
    }

    // MARK: - Tap wiring (T5 entry points)

    /// Binds an app's tape to its tap. Called from every tap-creation path
    /// (E14/E32). Does nothing when the app has no tape armed.
    func attach(to host: TapeTransportHosting, identifier: String, sampleRate: Double, appName: String? = nil) {
        if let appName {
            appNames[identifier] = appName
            transports[identifier]?.appName = appName
        }
        guard let transport = transports[identifier] ?? makeTransportIfEnabled(identifier: identifier) else { return }
        transport.attach(to: host, sampleRate: sampleRate)
    }

    /// Device switch / A2DP↔SCO re-rate for one app (E22 — the tape clears).
    func rateChanged(identifier: String, newRate: Double) {
        transports[identifier]?.rateChanged(to: newRate)
    }

    /// The app left the list (E29): frees the ring and forgets the transport.
    /// Rebuilt from config on demand.
    func release(identifier: String) {
        transports.removeValue(forKey: identifier)?.release()
    }

    /// Stale-tap cleanup (Erik's ruling, 2026-08-26, superseding E29's wording).
    /// A paused app is not a quit app: releasing an ARMED tape here means "pause
    /// Spotify for 30 s, come back, retro-record is empty" — silent data loss on
    /// the feature's headline flow. So the sweep frees the TAP and keeps the
    /// transport and its ring for any armed tape, engaged or not; the timeline
    /// simply freezes across the gap, as it already does for callback-dead gaps
    /// (E21). Accepted cost: up to the configured ring size stays resident while
    /// an armed app sits paused. The ring is freed only on quit, disarm, ignore.
    func releaseIfDisarmed(identifier: String) {
        guard let transport = transports[identifier], !transport.config.isEnabled else { return }
        release(identifier: identifier)
    }

    /// E20: an engaged (non-live) transport is the user actively listening to
    /// the past, so the engine must treat the app as audible in its idle/health
    /// logic — otherwise rewind playback dies the moment the app goes quiet,
    /// which is precisely when rewind is used.
    func isEngaged(identifier: String) -> Bool {
        guard let rt = transports[identifier]?.transport else { return false }
        return !rt.diagnosticsSnapshot().isPinnedToLive
    }

    // MARK: - UI access

    func transport(for identifier: String) -> AppTapeTransport? { transports[identifier] }

    /// Persisted config for an app that may have no transport yet — what the
    /// panel shows before the tape is armed.
    func config(for identifier: String) -> TapeTransportConfig {
        settingsManager.getTapeTransport(for: identifier) ?? TapeTransportConfig()
    }

    /// The transport the Tape panel edits, created on demand so an app whose
    /// tape has never been armed can arm it.
    func editableTransport(for identifier: String, appName: String) -> AppTapeTransport {
        appNames[identifier] = appName
        if let existing = transports[identifier] {
            existing.appName = appName
            return existing
        }
        return createTransport(identifier: identifier)
    }

    // MARK: - Creation

    private func makeTransportIfEnabled(identifier: String) -> AppTapeTransport? {
        guard config(for: identifier).isEnabled else { return nil }
        return createTransport(identifier: identifier)
    }

    private func createTransport(identifier: String) -> AppTapeTransport {
        let transport = AppTapeTransport(
            identifier: identifier,
            appName: appNames[identifier] ?? identifier,
            config: config(for: identifier),
            makeRT: makeRT,
            graceWait: graceWait
        )
        transport.onPersist = { [weak self] config in
            self?.settingsManager.setTapeTransport(config, for: identifier)
        }
        transport.onExport = onExport
        transports[identifier] = transport
        return transport
    }
}
