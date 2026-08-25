// FineTune/Audio/AUChain/AppAUChain.swift
import AudioToolbox
import AVFAudio
import Foundation
import os

// MARK: - Threading Model
//
// AppAUChain owns the AUAudioUnit instances for ONE app and runs the per-slot
// lifecycle state machine (spec §2.5). It bridges two execution domains — it is
// never on the RT thread at all:
//
// 1. **MainActor** — the whole class. Slot bookkeeping, render-state builds and
//    publication, persistence, plugin windows, the hang watchdog's clock.
//
// 2. **Builder queue** — ONE serial DispatchQueue per chain, for every blocking
//    third-party call: bus-format sets, `fullState` get/set, allocate/deallocate
//    RenderResources. Reached only via `withCheckedContinuation`. A hung plugin
//    wedges this queue, not the UI and not audio; the watchdog abandons the
//    wedged queue and installs a fresh one (§E) so the rest of the chain — and
//    every other chain, which owns its own queue — keeps building.
//
// **Deadlock rule (audited, and the reason for every `async` below)**: the main
// thread NEVER blocks on the builder queue. There is no `builderQueue.sync` in
// this file, and MainActor→builder hops are `await` *suspensions*, which leave
// the main runloop free. This matters because real plugins misbehave: an
// unlicensed AU (soothe3 failing iLok validation is the local example) can raise
// a MODAL ALERT during instantiation or state restore. A plugin that shows one
// from the builder queue has to `dispatch_sync` to main to do it — which
// resolves fine while main is merely suspended, and would deadlock instantly if
// main were blocked waiting on the queue. Builder→main hops are always
// `DispatchQueue.main.async`, never `.sync`, for the mirror-image reason.
//
// **Release ordering (E10 + E15) — the most dangerous rule in this file.**
// Publishing `nil` to the tap does not make the old render state unreachable:
// the RT thread may still be inside it for up to the 0.5s grace period the tap's
// deferred release is built around. So every teardown path is, in order:
//
//     capture fullState  →  publish nil / the new state  →  sleep(grace)  →  dealloc
//
// Capture-before-dealloc is E10 (a plugin's state is gone once its render
// resources are). Sleep-before-dealloc is E15: deallocating early is a
// use-after-free on the audio thread that will not crash until it ships. Both
// live in `releaseUnits(_:captureState:)`, adjacent, on purpose.

// MARK: - Unit seam

/// One hosted AU instance's blocking operations, behind a protocol so the
/// lifecycle tests can drive every failure branch deterministically (§8 T3).
///
/// Every method here is called from the builder queue (the one exception is
/// `captureState()` during `flushSync()` — see its comment), so implementations
/// must not assume MainActor. `makeNodeSpec` is the one MainActor-side read.
protocol AUChainUnit: AnyObject {
    /// The hosted unit, for the plugin window. `nil` for test stubs.
    var audioUnit: AUAudioUnit? { get }
    /// `maximumFramesToRender` + input/output bus formats (§2.5 configuring).
    func configure(sampleRate: Double) throws
    func restoreState(_ blob: Data) throws
    func allocate() throws
    func deallocate()
    func captureState() -> Data?
    /// Build-time snapshot for the render plan. MainActor; cheap; no allocation
    /// of render resources.
    func makeNodeSpec(sampleRate: Double) -> AUChainRenderState.NodeSpec
}

@MainActor
protocol AUChainUnitFactory {
    func instantiate(_ description: AudioComponentDescription) async throws -> AUChainUnit
}

enum AUChainUnitError: Error {
    case componentNotFound
    case unsupportedFormat
    case stateNotAPropertyList
}

// MARK: - Real implementation

/// Instantiates real Audio Units, in-process where the plugin allows it.
struct RealAUChainUnitFactory: AUChainUnitFactory {
    func instantiate(_ description: AudioComponentDescription) async throws -> AUChainUnit {
        do {
            // In-process keeps render blocks a plain function-pointer call, which
            // is what the RT contract is built on. Every AUv2 in an unsandboxed
            // host loads this way.
            return HostedAUChainUnit(try await Self.instantiateOnce(description, options: [.loadInProcess]))
        } catch {
            // A strict AUv3 may refuse in-process loading. Retrying without the
            // option lets Apple's extension process host it — still RT-callable
            // through the same block — instead of hard-failing the slot (§2.5).
            return HostedAUChainUnit(try await Self.instantiateOnce(description, options: []))
        }
    }

    private static func instantiateOnce(
        _ description: AudioComponentDescription,
        options: AudioComponentInstantiationOptions
    ) async throws -> AUAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            AUAudioUnit.instantiate(with: description, options: options) { unit, error in
                if let unit {
                    // AUAudioUnit is not Sendable; the instance is handed off to a
                    // single owner (AppAUChain) and never shared.
                    nonisolated(unsafe) let handoff = unit
                    continuation.resume(returning: handoff)
                } else {
                    continuation.resume(throwing: error ?? AUChainUnitError.componentNotFound)
                }
            }
        }
    }
}

/// Wraps one live `AUAudioUnit`. All state-mutating calls run on the builder queue.
final class HostedAUChainUnit: AUChainUnit {
    private let unit: AUAudioUnit
    var audioUnit: AUAudioUnit? { unit }

    init(_ unit: AUAudioUnit) { self.unit = unit }

    func configure(sampleRate: Double) throws {
        // Must precede allocation — the AU sizes its internal buffers from it (§2.5).
        unit.maximumFramesToRender = AUAudioFrameCount(AUChainRenderState.sliceCapacity)
        // DO NOT REMOVE: without an enabled input bus every render returns
        // kAudioUnitErr_NoConnection (-10876) and the pull block is never
        // invoked — the slot allocates, reports ready, and silently passes no
        // audio. Found empirically in T2; not in the spec.
        unit.inputBusses[0].isEnabled = true
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AUChainUnitError.unsupportedFormat
        }
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
    }

    func restoreState(_ blob: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(
            from: blob, options: [], format: nil
        ) as? [String: Any] else {
            throw AUChainUnitError.stateNotAPropertyList
        }
        // A plugin that raises an ObjC exception inside this setter takes the
        // process down — the accepted in-process posture (§E).
        unit.fullState = plist
    }

    func allocate() throws { try unit.allocateRenderResources() }

    func deallocate() { unit.deallocateRenderResources() }

    func captureState() -> Data? {
        guard let plist = unit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func makeNodeSpec(sampleRate: Double) -> AUChainRenderState.NodeSpec {
        AUChainRenderState.NodeSpec(
            audioUnit: unit,
            latencySamples: Int((unit.latency * sampleRate).rounded())
        )
    }
}

// MARK: - AppAUChain

@Observable
@MainActor
final class AppAUChain {

    /// Terminal lifecycle failures (§2.5). `.stateRestore` is reserved by the
    /// spec's state diagram; a restore failure is currently surfaced as a
    /// `stateRestoreFailed` flag on a READY slot instead — audio still works.
    enum FailureReason: Equatable {
        case missing
        case formatRefused
        case stateRestore
        case allocFailed
        case hung
    }

    enum SlotState: Equatable {
        case empty
        case instantiating
        case configuring
        case allocating
        case ready
        case failed(FailureReason)
    }

    struct Slot: Identifiable {
        let id: UUID
        var config: AUPluginConfig
        var state: SlotState = .empty
        /// `fullState` could not be restored — badge only, audio still works (§2.5).
        var stateRestoreFailed = false
        /// Latched by the NaN watchdog (§E); cleared when the user re-enables the slot.
        var isAutoBypassedForNaN = false
        /// Sustained pull/consume mismatch — the speed badge (§D).
        var showsSpeedBadge = false
        fileprivate var unit: AUChainUnit?

        /// True when the slot contributes a node to the published render state.
        var isActive: Bool { state == .ready && !config.isBypassed && !isAutoBypassedForNaN }
    }

    /// Consecutive invalid-audio strikes on one node before it is auto-bypassed (§E).
    static let nanStrikeLimit: Int32 = 100
    /// Consecutive pull/consume mismatch cycles before the speed badge shows (§D, E9).
    static let rateMismatchCycleLimit: Int32 = 10

    let identifier: String
    let appName: String

    private(set) var slots: [Slot] = []
    /// Σ node latencies of the currently published state (§E latency display).
    private(set) var totalLatencySamples: Int = 0
    /// True while this app has no chain of its own and mirrors the default (§4).
    var followsDefault: Bool

    /// Manager hook. `isStructural` distinguishes add/remove/reorder/bypass —
    /// which fork a default-following app onto its own chain — from a parameter
    /// capture, which writes back into the default chain (§4).
    var onPersist: @MainActor ([AUPluginConfig], Bool) -> Void = { _, _ in }

    private let factory: AUChainUnitFactory
    private let allocationTimeout: TimeInterval
    private let releaseGracePeriod: TimeInterval
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AUChain")

    private weak var host: AUChainHosting?
    /// The rate the instances are built at. Readable so the Effects panel can turn
    /// `totalLatencySamples` into milliseconds (§5.2); `nil` until a tap attaches.
    private(set) var sampleRate: Double?
    /// Replaced wholesale when a plugin wedges it (§E). `var` on purpose.
    private var builderQueue: DispatchQueue
    /// Bumped on every rate change and release so in-flight bring-ups can tell
    /// they are stale and dispose their instance instead of publishing it.
    private var generation: UInt64 = 0

    /// In-flight lifecycle Tasks (bring-up, rate rebuild), so callers can await
    /// a settled chain instead of polling for it.
    private var pendingTasks: [Task<Void, Never>] = []

    private var currentState: AUChainRenderState?
    /// Slot ids of `currentState`'s nodes, in the same order — the map used to
    /// attribute RT diagnostics back to slots.
    private var publishedSlotIDs: [UUID] = []

    init(
        identifier: String,
        appName: String,
        plugins: [AUPluginConfig],
        followsDefault: Bool,
        factory: AUChainUnitFactory = RealAUChainUnitFactory(),
        allocationTimeout: TimeInterval = 5.0,
        releaseGracePeriod: TimeInterval = 0.5
    ) {
        self.identifier = identifier
        self.appName = appName
        self.followsDefault = followsDefault
        self.factory = factory
        self.allocationTimeout = allocationTimeout
        self.releaseGracePeriod = releaseGracePeriod
        self.builderQueue = Self.makeBuilderQueue(identifier)
        self.slots = plugins.map { Slot(id: $0.id, config: $0) }
    }

    private static func makeBuilderQueue(_ identifier: String) -> DispatchQueue {
        DispatchQueue(label: "AUChainBuilder.\(identifier)", qos: .userInitiated)
    }

    // MARK: - Host wiring (called by AUChainManager)

    /// Binds the chain to a tap and starts (or republishes) the render state.
    /// Instances survive tap churn — a re-attach at the same rate only republishes.
    func attach(to host: AUChainHosting, sampleRate rate: Double) {
        self.host = host
        if let current = sampleRate, current != rate {
            // A tap came back on a different-rate device: rebuild the instances,
            // which republishes when it lands (§2.6 self-heal).
            rateChanged(to: rate)
            return
        }
        sampleRate = rate
        for slot in slots where slot.state == .empty {
            bringUp(slot.id)
        }
        rebuildRenderState()
    }

    /// The tap went away. Instances and their internal state stay alive — taps
    /// are disposable, chains are not (§2.1). Use `release()` for app teardown.
    func detach() {
        host?.setAUChain(nil)
        host = nil
        currentState = nil
        publishedSlotIDs = []
    }

    /// Device switch / A2DP↔SCO re-rate (§2.5): drop the chain first, then
    /// dealloc → reformat → realloc every instance. Plugin state survives, open
    /// plugin windows stay open.
    func rateChanged(to newRate: Double) {
        guard sampleRate != newRate else { return }
        sampleRate = newRate
        generation &+= 1
        publish(nil, slotIDs: [])
        let generationAtStart = generation
        pendingTasks.append(Task { @MainActor in
            await self.rebuildInstances(generation: generationAtStart, rate: newRate)
        })
    }

    /// App left the list (§2.6, E10): capture state, close windows, drop the
    /// chain, then deallocate after the grace period.
    func release() {
        generation &+= 1
        let entries = slots.compactMap { slot in slot.unit.map { (slotID: slot.id, unit: $0) } }
        for slot in slots {
            AUPluginWindowController.shared.close(slotID: slot.id)  // E5
        }
        publish(nil, slotIDs: [])
        host = nil
        for index in slots.indices {
            slots[index].unit = nil
            slots[index].state = .empty
        }
        releaseUnits(entries, captureState: true)
    }

    /// Adopt a new configuration (a default-chain edit made elsewhere, or
    /// reset-to-default). Slots whose id survives keep their live instance.
    func reload(plugins: [AUPluginConfig], followsDefault: Bool) {
        self.followsDefault = followsDefault
        let surviving = Set(plugins.map(\.id))
        let dropped = slots.filter { !surviving.contains($0.id) }
        for slot in dropped {
            AUPluginWindowController.shared.close(slotID: slot.id)  // E5
        }

        slots = plugins.map { config in
            guard var existing = slots.first(where: { $0.id == config.id }) else {
                return Slot(id: config.id, config: config)
            }
            existing.config = config
            return existing
        }

        rebuildRenderState()
        releaseUnits(dropped.compactMap { slot in slot.unit.map { (slotID: slot.id, unit: $0) } },
                     captureState: false)
        for slot in slots where slot.state == .empty {
            bringUp(slot.id)
        }
    }

    // MARK: - Structural edits (§4 — each one persists and forks)

    func addPlugin(_ config: AUPluginConfig) {
        captureStates(slotIDs: slots.map(\.id))
        slots.append(Slot(id: config.id, config: config))
        persist(structural: true)
        bringUp(config.id)
    }

    func removePlugin(id: UUID) {
        guard let slotIndex = index(of: id) else { return }
        captureStates(slotIDs: slots.map(\.id).filter { $0 != id })
        let removed = slots.remove(at: slotIndex)
        AUPluginWindowController.shared.close(slotID: id)  // E5
        persist(structural: true)
        rebuildRenderState()
        releaseUnits(removed.unit.map { [(slotID: id, unit: $0)] } ?? [], captureState: false)
    }

    func removeAll() {
        let entries = slots.compactMap { slot in slot.unit.map { (slotID: slot.id, unit: $0) } }
        for slot in slots {
            AUPluginWindowController.shared.close(slotID: slot.id)  // E5
        }
        slots.removeAll()
        persist(structural: true)
        rebuildRenderState()
        releaseUnits(entries, captureState: false)
    }

    /// SwiftUI `onMove` semantics, spelled out rather than pulling SwiftUI into
    /// the audio layer for one collection helper.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        captureStates(slotIDs: slots.map(\.id))
        let moved = source.map { slots[$0] }
        var remaining = slots
        for offset in source.sorted(by: >) { remaining.remove(at: offset) }
        let insertion = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: min(max(insertion, 0), remaining.count))
        slots = remaining
        persist(structural: true)
        rebuildRenderState()
    }

    func setBypassed(_ bypassed: Bool, id: UUID) {
        guard let slotIndex = index(of: id) else { return }
        slots[slotIndex].config.isBypassed = bypassed
        if !bypassed {
            // Re-enabling by hand clears the invalid-audio latch and gives the
            // plugin another chance.
            slots[slotIndex].isAutoBypassedForNaN = false
        }
        persist(structural: true)
        rebuildRenderState()
    }

    // MARK: - Plugin window

    func openWindow(id: UUID) {
        guard let slotIndex = index(of: id), let unit = slots[slotIndex].unit?.audioUnit else { return }
        AUPluginWindowController.shared.open(
            slotID: id,
            audioUnit: unit,
            pluginName: slots[slotIndex].config.displayName,
            appName: appName
        ) { [weak self] in
            // Window close is a capture trigger (§4). The controller's forced
            // close(slotID:) deliberately does not fire this — teardown paths
            // capture for themselves, before dealloc.
            self?.captureStates(slotIDs: [id])
        }
    }

    // MARK: - fullState capture (§4 triggers)

    /// Snapshots `fullState` for the given ready slots on the builder queue and
    /// persists the blobs. Never blocks MainActor.
    func captureStates(slotIDs: [UUID]) {
        let entries: [(UUID, AUChainUnit)] = slotIDs.compactMap { id in
            guard let slotIndex = index(of: id), slots[slotIndex].state == .ready,
                  let unit = slots[slotIndex].unit else { return nil }
            return (id, unit)
        }
        guard !entries.isEmpty else { return }
        nonisolated(unsafe) let items = entries
        builderQueue.async { [weak self] in
            let blobs = items.map { ($0.0, $0.1.captureState()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.storeCapturedBlobs(blobs) }
            }
        }
    }

    /// 60s cadence while any plugin window is open (§4).
    func captureOpenWindowStates() {
        let open = Set(AUPluginWindowController.shared.openSlotIDs)
        captureStates(slotIDs: slots.map(\.id).filter(open.contains))
    }

    /// App-termination flush (§4). Reads `fullState` on the MAIN thread instead
    /// of hopping to the builder queue: there is nothing left to await against at
    /// quit, and blocking MainActor on that queue is the one thing this class
    /// never does (see the deadlock rule in the header). Only `.ready` slots are
    /// read — nothing else is in flight against them at quit.
    func flushSync() {
        let blobs: [(UUID, Data?)] = slots.compactMap { slot in
            guard slot.state == .ready, let unit = slot.unit else { return nil }
            return (slot.id, unit.captureState())
        }
        storeCapturedBlobs(blobs)
    }

    private func storeCapturedBlobs(_ blobs: [(UUID, Data?)]) {
        var changed = false
        for (id, blob) in blobs {
            guard let blob, let slotIndex = index(of: id), slots[slotIndex].config.fullState != blob else { continue }
            slots[slotIndex].config.fullState = blob
            changed = true
        }
        if changed { persist(structural: false) }
    }

    // MARK: - Diagnostics polling (2s cadence, §D/§E)

    func pollDiagnostics() {
        guard let state = currentState else { return }
        let snapshots = state.diagnosticsSnapshot()
        guard snapshots.count == publishedSlotIDs.count else { return }
        var needsRebuild = false
        for (offset, snapshot) in snapshots.enumerated() {
            guard let slotIndex = index(of: publishedSlotIDs[offset]) else { continue }
            if snapshot.nanStrikes >= Self.nanStrikeLimit, !slots[slotIndex].isAutoBypassedForNaN {
                let name = slots[slotIndex].config.displayName
                logger.error("Auto-bypassing \(name, privacy: .public) — produced invalid audio")
                slots[slotIndex].isAutoBypassedForNaN = true
                needsRebuild = true
            }
            slots[slotIndex].showsSpeedBadge = snapshot.consecutiveMismatchCycles >= Self.rateMismatchCycleLimit
        }
        if needsRebuild { rebuildRenderState() }
    }

    // MARK: - Render-state build (cheap, MainActor)

    private func rebuildRenderState() {
        guard let host, let rate = sampleRate else { return }
        // §E stale-device guard: a build that lands after the tap moved to a
        // different rate must rebuild rather than publish.
        if let hostRate = host.nominalSampleRate, hostRate != rate {
            rateChanged(to: hostRate)
            return
        }
        let active = slots.filter(\.isActive)
        guard !active.isEmpty else {
            publish(nil, slotIDs: [])
            return
        }
        let specs = active.compactMap { $0.unit?.makeNodeSpec(sampleRate: rate) }
        publish(AUChainRenderState(nodes: specs, sampleRate: rate), slotIDs: active.map(\.id))
    }

    private func publish(_ state: AUChainRenderState?, slotIDs: [UUID]) {
        currentState = state
        publishedSlotIDs = slotIDs
        totalLatencySamples = state?.totalLatencySamples ?? 0
        host?.setAUChain(state)
    }

    // MARK: - Slot lifecycle (§2.5)

    private func bringUp(_ slotID: UUID) {
        guard sampleRate != nil else { return }
        let generationAtStart = generation
        pendingTasks.append(Task { @MainActor in
            await self.bringSlotUp(slotID, existing: nil, generation: generationAtStart)
        })
    }

    /// Awaits every in-flight lifecycle Task, including ones they spawn. The
    /// loop matters: a bring-up can queue another (rate re-entry, stale-device
    /// rebuild) while it is being awaited.
    func waitForPendingWork() async {
        while !pendingTasks.isEmpty {
            let inFlight = pendingTasks
            pendingTasks.removeAll()
            for task in inFlight { await task.value }
        }
    }

    /// empty → instantiating → configuring → allocating → ready.
    /// `existing` non-nil means a rate re-entry on a live instance: its internal
    /// state is kept, so no `fullState` restore happens.
    private func bringSlotUp(_ slotID: UUID, existing: AUChainUnit?, generation generationAtStart: UInt64) async {
        guard let rate = sampleRate, let startIndex = index(of: slotID) else { return }

        var built = existing
        if built == nil {
            setState(slotID, .instantiating)
            let description = slots[startIndex].config.componentDescription
            let name = slots[startIndex].config.displayName
            do {
                built = try await factory.instantiate(description)
            } catch {
                // Component not found: the slot KEEPS its position and its blob,
                // so reinstalling the plugin revives it (§E).
                logger.error("Instantiation failed for \(name, privacy: .public): \(error.localizedDescription)")
                setState(slotID, .failed(.missing))
                return
            }
        }
        guard let unit = built else { return }
        guard isCurrent(generationAtStart), index(of: slotID) != nil else {
            releaseUnits([(slotID: slotID, unit: unit)], captureState: false)
            return
        }

        setState(slotID, .configuring)
        if let message = await runOnBuilder({ try unit.configure(sampleRate: rate) }) {
            logger.error("Format refused by \(slotID, privacy: .public): \(message, privacy: .public)")
            setState(slotID, .failed(.formatRefused))
            releaseUnits([(slotID: slotID, unit: unit)], captureState: false)
            return
        }
        guard isCurrent(generationAtStart), let configIndex = index(of: slotID) else {
            releaseUnits([(slotID: slotID, unit: unit)], captureState: false)
            return
        }

        var restoreFailed = false
        if existing == nil, let blob = slots[configIndex].config.fullState {
            // A restore failure is NOT a lifecycle failure: the plugin runs with
            // its defaults and the row shows a badge (§2.5).
            restoreFailed = await runOnBuilder({ try unit.restoreState(blob) }) != nil
        }

        setState(slotID, .allocating)
        switch await runOnBuilderWatchdogged({ try unit.allocate() }) {
        case .ok:
            break
        case .failed(let message):
            logger.error("allocateRenderResources failed for \(slotID, privacy: .public): \(message, privacy: .public)")
            setState(slotID, .failed(.allocFailed))
            releaseUnits([(slotID: slotID, unit: unit)], captureState: false)
            return
        case .timedOut:
            // The queue — and the thread it owns — is wedged inside third-party
            // code that may never return. Abandon both and never touch this
            // instance again; the zombie thread leaks by design (§E).
            logger.error("Plugin hung in allocateRenderResources — abandoning builder queue for \(self.identifier, privacy: .public)")
            builderQueue = Self.makeBuilderQueue(identifier)
            setState(slotID, .failed(.hung))
            return
        }

        guard isCurrent(generationAtStart), let readyIndex = index(of: slotID) else {
            releaseUnits([(slotID: slotID, unit: unit)], captureState: false)
            return
        }
        slots[readyIndex].unit = unit
        slots[readyIndex].stateRestoreFailed = restoreFailed
        slots[readyIndex].state = .ready
        rebuildRenderState()
    }

    /// Rate re-entry for every live instance (§2.5). The caller has already
    /// published `nil`, so the grace period is waited out before the deallocs.
    private func rebuildInstances(generation generationAtStart: UInt64, rate: Double) async {
        let live = slots.compactMap { slot in slot.unit.map { (slotID: slot.id, unit: $0) } }
        if !live.isEmpty {
            nonisolated(unsafe) let items = live
            let grace = releaseGracePeriod
            _ = await runOnBuilder {
                // E15: the RT thread can still be inside the state we just
                // nil-swapped away. Wait it out BEFORE deallocating anything it
                // points into.
                Thread.sleep(forTimeInterval: grace)
                for item in items { item.unit.deallocate() }
            }
        }
        guard isCurrent(generationAtStart) else { return }

        for entry in live {
            guard isCurrent(generationAtStart) else { return }
            if let slotIndex = index(of: entry.slotID) {
                slots[slotIndex].unit = nil
            }
            await bringSlotUp(entry.slotID, existing: entry.unit, generation: generationAtStart)
        }
        for slot in slots where slot.state == .empty {
            await bringSlotUp(slot.id, existing: nil, generation: generationAtStart)
        }
        guard isCurrent(generationAtStart) else { return }
        rebuildRenderState()
    }

    // MARK: - Release (E10 + E15 ordering lives here)

    /// Captures `fullState` (E10) and then, after the RT grace period (E15),
    /// deallocates and drops the instances.
    ///
    /// The caller MUST have already published the new render state (or `nil`) on
    /// MainActor before calling this — that publication is what starts the grace
    /// window this method waits out. The three steps are adjacent below so the
    /// ordering can be read in one glance and proven in one test.
    private func releaseUnits(_ entries: [(slotID: UUID, unit: AUChainUnit)], captureState: Bool) {
        guard !entries.isEmpty else { return }
        nonisolated(unsafe) let items = entries
        let grace = releaseGracePeriod
        // Strong `self`: the block is one-shot and bounded, and the captured
        // blobs must still find their slots when they land back on MainActor.
        builderQueue.async {
            // 1. Capture BEFORE dealloc — a plugin's state is gone with its
            //    render resources (E10).
            if captureState {
                let blobs = items.map { ($0.slotID, $0.unit.captureState()) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.storeCapturedBlobs(blobs) }
                }
            }
            // 2. Wait out the render-state grace period. The RT thread may still
            //    be executing render blocks that belong to these units (E15).
            Thread.sleep(forTimeInterval: grace)
            // 3. Only now is deallocation safe.
            for item in items { item.unit.deallocate() }
        }
    }

    // MARK: - Builder-queue plumbing

    /// `Error` is not Sendable and the payload only ever crosses back to
    /// MainActor to be logged, so failures travel as their description.
    private enum BuilderOutcome: Sendable {
        case ok
        case failed(String)
        case timedOut
    }

    /// Runs `body` on the builder queue. The hop is an `await` suspension, never
    /// a block, so the main runloop stays live for a plugin that raises a modal.
    private func runOnBuilder(_ body: @escaping () throws -> Void) async -> String? {
        let queue = builderQueue
        nonisolated(unsafe) let work = body
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                do {
                    try work()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    /// Same, raced against a MainActor timeout (§E hang watchdog). On timeout the
    /// builder call is left running forever on the now-doomed queue.
    private func runOnBuilderWatchdogged(_ body: @escaping () throws -> Void) async -> BuilderOutcome {
        let queue = builderQueue
        let timeout = allocationTimeout
        nonisolated(unsafe) let work = body
        let race = OneShot<BuilderOutcome>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<BuilderOutcome, Never>) in
            race.arm(continuation)
            queue.async {
                do {
                    try work()
                    race.finish(.ok)
                } catch {
                    race.finish(.failed(error.localizedDescription))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { race.finish(.timedOut) }
        }
    }

    /// Resumes a continuation exactly once, from whichever racer wins.
    private final class OneShot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func arm(_ continuation: CheckedContinuation<T, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: T) {
            lock.lock()
            let winner = continuation
            continuation = nil
            lock.unlock()
            winner?.resume(returning: value)
        }
    }

    // MARK: - Small helpers

    private func index(of slotID: UUID) -> Int? {
        slots.firstIndex { $0.id == slotID }
    }

    private func isCurrent(_ generationAtStart: UInt64) -> Bool {
        generation == generationAtStart
    }

    private func setState(_ slotID: UUID, _ state: SlotState) {
        guard let slotIndex = index(of: slotID) else { return }
        slots[slotIndex].state = state
    }

    private func persist(structural: Bool) {
        onPersist(slots.map(\.config), structural)
    }
}
