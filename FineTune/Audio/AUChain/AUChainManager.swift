// FineTune/Audio/AUChain/AUChainManager.swift
import Foundation
import os

/// What an `AppAUChain` needs from the thing that renders it. `ProcessTapController`
/// conforms (T4); tests use a fake. Keeping the manager on this protocol instead of
/// the concrete tap keeps the whole lifecycle layer out of the RT lane.
@MainActor
protocol AUChainHosting: AnyObject {
    /// Publishes the render plan to the tap (atomic pointer swap + 0.5s deferred
    /// release of the previous state, §2.2). `nil` drops the chain.
    func setAUChain(_ state: AUChainRenderState?)
    /// The tap's current nominal rate — used to catch a build that landed after
    /// the device moved (§E stale-device guard).
    var nominalSampleRate: Double? { get }
}

/// Registry of `identifier → AppAUChain`, owner of the default chain, and the
/// single timer that drives both polling cadences (§4, §E).
///
/// Chains are created lazily: an app gets one when it has a chain config of its
/// own, or when the default chain is non-empty. An app with NO key in
/// `appAUChains` follows the default chain but gets its OWN instances (§4) —
/// instances are never shared across taps.
@Observable
@MainActor
final class AUChainManager {

    /// Diagnostics cadence (§E). The 60s `fullState` capture (§4) rides the same
    /// timer every `captureTickInterval` ticks.
    private static let pollInterval: TimeInterval = 2.0
    private static let captureTickInterval = 30

    private let settingsManager: SettingsManager
    private let factory: AUChainUnitFactory
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUChainManager")

    private var chains: [String: AppAUChain] = [:]
    private var appNames: [String: String] = [:]
    private var timer: Timer?
    private var tick = 0

    init(settingsManager: SettingsManager, factory: AUChainUnitFactory = RealAUChainUnitFactory()) {
        self.settingsManager = settingsManager
        self.factory = factory
    }

    // MARK: - Tap wiring (T4 entry points)

    /// Binds an app's chain to its tap and starts building. Called from every tap
    /// creation path (§2.6, E14). Does nothing when the app has no chain to host.
    func attach(to host: AUChainHosting, identifier: String, sampleRate: Double, appName: String? = nil) {
        if let appName { appNames[identifier] = appName }
        guard let chain = chains[identifier] ?? makeChainIfConfigured(identifier: identifier) else { return }
        chain.attach(to: host, sampleRate: sampleRate)
    }

    /// Device switch / A2DP↔SCO re-rate for one app (§2.5 rate rebuild).
    func rateChanged(identifier: String, newRate: Double) {
        chains[identifier]?.rateChanged(to: newRate)
    }

    /// The app's tap went away, but the app has not. Instances stay alive so a
    /// health-recreate or sleep/wake keeps every plugin's internal state (§2.1).
    func detach(identifier: String) {
        chains[identifier]?.detach()
    }

    /// The app left the list (§2.6, E10): capture, close windows, release
    /// instances, and forget the chain. It is rebuilt from config on demand.
    func release(identifier: String) {
        guard let chain = chains.removeValue(forKey: identifier) else { return }
        chain.release()
        stopTimerIfIdle()
    }

    /// App-termination flush (§4). Synchronous by necessity — see `AppAUChain.flushSync`.
    func flushSync() {
        for chain in chains.values { chain.flushSync() }
    }

    // MARK: - UI access

    func chain(for identifier: String) -> AppAUChain? { chains[identifier] }

    /// The chain the Effects panel edits, created on demand so an app with no
    /// plugins yet can have one added.
    func editableChain(for identifier: String, appName: String) -> AppAUChain {
        appNames[identifier] = appName
        if let existing = chains[identifier] { return existing }
        return makeChain(identifier: identifier)
    }

    var defaultChain: AUChainConfig {
        settingsManager.defaultAUChain ?? AUChainConfig(plugins: [])
    }

    /// Replaces the default chain and pushes it into every app still following it.
    func setDefaultChain(_ config: AUChainConfig) {
        settingsManager.defaultAUChain = config
        for chain in chains.values where chain.followsDefault {
            chain.reload(plugins: config.plugins, followsDefault: true)
        }
    }

    /// "Use Default Chain" (§5.2): drops the app's custom chain and adopts the default.
    func resetToDefault(identifier: String) {
        settingsManager.clearAUChain(for: identifier)
        chains[identifier]?.reload(plugins: defaultChain.plugins, followsDefault: true)
    }

    // MARK: - Chain creation

    private func makeChainIfConfigured(identifier: String) -> AppAUChain? {
        let custom = settingsManager.getAUChain(for: identifier)
        let plugins = custom?.plugins ?? defaultChain.plugins
        // Nothing to host: an app with an explicitly empty chain, or no custom
        // chain and an empty default. Stay lazy (§2.1).
        guard !plugins.isEmpty else { return nil }
        return makeChain(identifier: identifier)
    }

    private func makeChain(identifier: String) -> AppAUChain {
        let custom = settingsManager.getAUChain(for: identifier)
        // Absence of a key means "follows default"; presence with an empty
        // plugins array means "explicitly no effects" (§4). Do not collapse them.
        let followsDefault = custom == nil
        let chain = AppAUChain(
            identifier: identifier,
            appName: appNames[identifier] ?? identifier,
            plugins: custom?.plugins ?? defaultChain.plugins,
            followsDefault: followsDefault,
            factory: factory
        )
        chain.onPersist = { [weak self] plugins, isStructural in
            self?.persist(plugins, isStructural: isStructural, identifier: identifier)
        }
        chains[identifier] = chain
        startTimerIfNeeded()
        return chain
    }

    /// §4 fork semantics. A structural edit on a default-following app gives it
    /// its own chain; a parameter capture writes back into the default instead
    /// (last capture wins across apps — E7).
    private func persist(_ plugins: [AUPluginConfig], isStructural: Bool, identifier: String) {
        guard let chain = chains[identifier] else { return }
        guard chain.followsDefault else {
            settingsManager.setAUChain(AUChainConfig(plugins: plugins), for: identifier)
            return
        }
        if isStructural {
            logger.debug("Forking \(identifier, privacy: .public) onto its own AU chain")
            chain.followsDefault = false
            settingsManager.setAUChain(AUChainConfig(plugins: plugins), for: identifier)
        } else {
            settingsManager.defaultAUChain = AUChainConfig(plugins: plugins)
        }
    }

    // MARK: - Polling

    private func startTimerIfNeeded() {
        guard timer == nil, !chains.isEmpty else { return }
        // Self-invalidating rather than deinit-invalidated: a MainActor deinit
        // cannot touch isolated state, and a repeating timer outliving its
        // manager would tick forever.
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.onTick() }
        }
    }

    private func stopTimerIfIdle() {
        guard chains.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    private func onTick() {
        tick &+= 1
        for chain in chains.values { chain.pollDiagnostics() }
        guard tick % Self.captureTickInterval == 0 else { return }
        for chain in chains.values { chain.captureOpenWindowStates() }
    }
}
