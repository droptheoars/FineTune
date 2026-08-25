// FineTuneTests/AUChainLifecycleTests.swift
// Lifecycle gate for AppAUChain / AUChainManager (spec §8 T3).
//
// Every branch is driven through the AUChainUnit seam rather than real plugins,
// so the failure modes that matter — a missing component, a refused format, a
// failed state restore, and a plugin that never returns from
// allocateRenderResources — are deterministic and fast. The stub records an
// ORDERED, timestamped event log, which is what lets the release test assert
// capture-before-dealloc and the E15 grace window rather than merely asserting
// that both happened.

import AudioToolbox
import Foundation
import Testing
@testable import FineTune

// MARK: - Fakes

private enum StubError: Error {
    case notInstalled
    case formatRefused
    case badState
}

private enum StubEvent: Equatable {
    case configure
    case restore
    case allocate
    case deallocate
    case capture
    case makeNodeSpec
}

/// Thread-safe ordered log — the stub is driven from the builder queue.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(event: StubEvent, at: Date)] = []

    func record(_ event: StubEvent) {
        lock.lock()
        entries.append((event, Date()))
        lock.unlock()
    }

    var events: [StubEvent] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.event)
    }

    /// True when a `.makeNodeSpec` occurs while the unit's render resources are
    /// gone — i.e. the published render plan captured a render block after
    /// `deallocateRenderResources` and before the matching re-allocate (F1).
    var capturedNodeSpecWhileDeallocated: Bool {
        var allocated = false
        for event in events {
            switch event {
            case .allocate: allocated = true
            case .deallocate: allocated = false
            case .makeNodeSpec where !allocated: return true
            default: break
            }
        }
        return false
    }

    func firstTime(of event: StubEvent) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.event == event }?.at
    }
}

private final class StubUnit: AUChainUnit, @unchecked Sendable {
    let log = EventLog()
    var configureError: Error?
    var restoreError: Error?
    var allocateError: Error?
    /// Injected blocking work — the deterministic stand-in for a hung plugin.
    var allocateBlockFor: TimeInterval?
    var capturedBlob = Data([0xAB, 0xCD])

    var audioUnit: AUAudioUnit? { nil }

    func configure(sampleRate: Double) throws {
        log.record(.configure)
        if let configureError { throw configureError }
    }

    func restoreState(_ blob: Data) throws {
        log.record(.restore)
        if let restoreError { throw restoreError }
    }

    func allocate() throws {
        if let allocateBlockFor { Thread.sleep(forTimeInterval: allocateBlockFor) }
        log.record(.allocate)
        if let allocateError { throw allocateError }
    }

    func deallocate() { log.record(.deallocate) }

    func captureState() -> Data? {
        log.record(.capture)
        return capturedBlob
    }

    func makeNodeSpec(sampleRate: Double) -> AUChainRenderState.NodeSpec {
        log.record(.makeNodeSpec)
        // Silent passthrough node — never actually rendered by these tests.
        return AUChainRenderState.NodeSpec(rawRenderBlock: { _, _, _, _, _, _ in noErr }, latencySamples: 0)
    }
}

@MainActor
private final class StubFactory: AUChainUnitFactory {
    var instantiationFails = false
    var configureThrows = false
    var restoreThrows = false
    /// Applied to the FIRST unit only, so a hang can be isolated to one slot.
    var blockFirstAllocateFor: TimeInterval?
    private(set) var made: [StubUnit] = []

    func instantiate(_ description: AudioComponentDescription) async throws -> AUChainUnit {
        if instantiationFails { throw StubError.notInstalled }
        let unit = StubUnit()
        if configureThrows { unit.configureError = StubError.formatRefused }
        if restoreThrows { unit.restoreError = StubError.badState }
        if made.isEmpty, let blockFirstAllocateFor { unit.allocateBlockFor = blockFirstAllocateFor }
        made.append(unit)
        return unit
    }
}

@MainActor
private final class FakeHost: AUChainHosting {
    var published: [AUChainRenderState?] = []
    var publishTimes: [Date] = []
    var rate: Double? = 48000

    var nominalSampleRate: Double? { rate }

    func setAUChain(_ state: AUChainRenderState?) {
        published.append(state)
        publishTimes.append(Date())
    }

    var lastNilPublishTime: Date? {
        for index in published.indices.reversed() where published[index] == nil {
            return publishTimes[index]
        }
        return nil
    }
}

// MARK: - Helpers

private func makeConfig(name: String, blob: Data? = nil) -> AUPluginConfig {
    AUPluginConfig(
        id: UUID(),
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x64656C79,   // 'dely'
        componentManufacturer: kAudioUnitManufacturer_Apple,
        displayName: name,
        isBypassed: false,
        fullState: blob
    )
}

/// Polls on the main actor until `condition` holds. Lifecycle transitions are
/// driven by detached Tasks, so tests observe them rather than awaiting them.
/// The timeout is generous on purpose: the suite runs in parallel and the main
/// actor is heavily contended, so a tight wall-clock bound here measures the
/// machine's load, not the code under test.
@MainActor
private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 20.0,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            Issue.record("Timed out waiting for: \(description)")
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor
private func makeChain(
    plugins: [AUPluginConfig],
    factory: StubFactory,
    allocationTimeout: TimeInterval = 5.0,
    grace: TimeInterval = 0.5
) -> AppAUChain {
    AppAUChain(
        identifier: "com.test.app",
        appName: "Test App",
        plugins: plugins,
        followsDefault: false,
        factory: factory,
        allocationTimeout: allocationTimeout,
        releaseGracePeriod: grace
    )
}

// MARK: - Lifecycle failures

@Suite("AppAUChain — lifecycle failure modes")
@MainActor
struct AppAUChainFailureTests {

    @Test("Missing component fails to .missing, keeping the slot's position and blob")
    func missingComponentKeepsSlotAndBlob() async {
        let blob = Data([0x01, 0x02, 0x03])
        let first = makeConfig(name: "Gone Plugin", blob: blob)
        let second = makeConfig(name: "Also Gone")
        let factory = StubFactory()
        factory.instantiationFails = true
        let chain = makeChain(plugins: [first, second], factory: factory)
        let host = FakeHost()

        chain.attach(to: host, sampleRate: 48000)
        await chain.waitForPendingWork()
        #expect(chain.slots.allSatisfy { $0.state == .failed(.missing) })

        // Position kept, blob kept — reinstalling the plugin revives the slot (§E).
        #expect(chain.slots.count == 2)
        #expect(chain.slots[0].id == first.id)
        #expect(chain.slots[1].id == second.id)
        #expect(chain.slots[0].config.fullState == blob)
        #expect(chain.slots[0].config.displayName == "Gone Plugin")
        // A chain with no ready slots publishes nothing wet.
        #expect(host.published.allSatisfy { $0 == nil })
    }

    @Test("A refused bus format fails the slot to .formatRefused")
    func formatRefusedFailsSlot() async {
        let factory = StubFactory()
        factory.configureThrows = true
        let chain = makeChain(plugins: [makeConfig(name: "Picky Plugin")], factory: factory)

        chain.attach(to: FakeHost(), sampleRate: 48000)
        await chain.waitForPendingWork()
        #expect(chain.slots[0].state == .failed(.formatRefused))

        #expect(factory.made.count == 1)
        // Configure was attempted; allocation never was.
        #expect(factory.made[0].log.events.contains(.configure))
        #expect(!factory.made[0].log.events.contains(.allocate))
    }

    @Test("A failed fullState restore still reaches ready, flagged for the badge")
    func restoreFailureStillReady() async {
        let factory = StubFactory()
        factory.restoreThrows = true
        let chain = makeChain(plugins: [makeConfig(name: "Old Settings", blob: Data([0x09]))], factory: factory)
        let host = FakeHost()

        chain.attach(to: host, sampleRate: 48000)
        await chain.waitForPendingWork()
        #expect(chain.slots[0].state == .ready)

        // Restore failure is a badge, not a lifecycle failure — audio still works.
        #expect(chain.slots[0].stateRestoreFailed)
        #expect(factory.made[0].log.events == [.configure, .restore, .allocate, .makeNodeSpec])
        #expect((host.published.last ?? nil) != nil)
    }

    @Test("A plugin that never returns from allocate is watchdogged, and the chain keeps building")
    func watchdogAbandonsWedgedQueue() async {
        let factory = StubFactory()
        // The injected blocking closure outlives the whole test, so every
        // assertion below is about the watchdog, never about the blocker
        // happening to finish. Proof is by ORDERING against the blocker's own
        // log rather than by wall clock — the suite runs in parallel and the
        // main actor is contended, which makes clock bounds meaningless.
        factory.blockFirstAllocateFor = 30.0
        let chain = makeChain(
            plugins: [makeConfig(name: "Hung Plugin")],
            factory: factory,
            allocationTimeout: 0.15
        )

        chain.attach(to: FakeHost(), sampleRate: 48000)
        await chain.waitForPendingWork()
        #expect(chain.slots[0].state == .failed(.hung))
        let wedged = factory.made[0].log
        #expect(!wedged.events.contains(.allocate), "the wedged allocate has not returned — the watchdog fired, not the blocker")

        // The wedged queue was abandoned: a slot added afterwards builds on a
        // fresh one while the old queue is still stuck inside the blocker.
        chain.addPlugin(makeConfig(name: "Healthy Plugin"))
        await chain.waitForPendingWork()
        #expect(chain.slots.last?.state == .ready)
        #expect(!wedged.events.contains(.allocate), "the old queue is still wedged, and the chain built anyway")
    }
}

// MARK: - Rate rebuild

@Suite("AppAUChain — rate rebuild")
@MainActor
struct AppAUChainRateRebuildTests {

    @Test("A rate rebuild never publishes a node whose render resources are deallocated")
    func rebuildNeverPublishesDeallocatedUnits() async {
        let factory = StubFactory()
        let chain = makeChain(
            plugins: [makeConfig(name: "First"), makeConfig(name: "Second")],
            factory: factory,
            grace: 0.05
        )
        let host = FakeHost()
        host.rate = 44100

        chain.attach(to: host, sampleRate: 44100)
        await chain.waitForPendingWork()
        #expect(chain.slots.allSatisfy { $0.state == .ready })

        // Device switch 44.1k → 48k. Every instance is deallocated and re-set-up;
        // no intermediate publish may reference one whose resources are gone.
        host.rate = 48000
        chain.rateChanged(to: 48000)
        await chain.waitForPendingWork()

        #expect(chain.slots.allSatisfy { $0.state == .ready })
        #expect(factory.made.count == 2, "the rebuild reuses instances, it does not re-instantiate")
        for (index, unit) in factory.made.enumerated() {
            #expect(
                !unit.log.capturedNodeSpecWhileDeallocated,
                "slot \(index) was published into a render state while deallocated (F1)"
            )
        }
    }
}

// MARK: - Release ordering (E10 + E15)

@Suite("AppAUChain — release ordering")
@MainActor
struct AppAUChainReleaseTests {

    @Test("Release captures fullState before dealloc, and deallocs only after the grace period")
    func captureBeforeDeallocAfterGrace() async throws {
        let grace: TimeInterval = 0.2
        let factory = StubFactory()
        let chain = makeChain(plugins: [makeConfig(name: "Live Plugin")], factory: factory, grace: grace)
        let host = FakeHost()
        var persisted: [AUPluginConfig] = []
        chain.onPersist = { plugins, _ in persisted = plugins }

        chain.attach(to: host, sampleRate: 48000)
        await chain.waitForPendingWork()
        #expect(chain.slots[0].state == .ready)
        #expect((host.published.last ?? nil) != nil)

        chain.release()

        // The nil swap is synchronous on MainActor — it must already have
        // happened when release() returns, because it is what starts the grace
        // window the dealloc waits out.
        #expect((host.published.last ?? nil) == nil)
        let nilPublishedAt = try #require(host.lastNilPublishTime)

        let log = factory.made[0].log
        await waitUntil("the deallocation to land") { log.events.contains(.deallocate) }

        let events = log.events
        let captureIndex = try #require(events.firstIndex(of: .capture))
        let deallocIndex = try #require(events.firstIndex(of: .deallocate))
        // E10: a plugin's state is gone once its render resources are.
        #expect(captureIndex < deallocIndex, "fullState must be captured BEFORE dealloc")

        // E15: the RT thread can still be inside the state that was just
        // nil-swapped away. Deallocating before the grace elapses is a
        // use-after-free on the audio thread.
        let deallocatedAt = try #require(log.firstTime(of: .deallocate))
        #expect(deallocatedAt.timeIntervalSince(nilPublishedAt) >= grace,
                "dealloc must wait out the \(grace)s render-state grace period")

        // The captured blob made it back into the persisted config.
        await waitUntil("the captured blob to persist") {
            persisted.first?.fullState == Data([0xAB, 0xCD])
        }
    }

    @Test("Removing a slot publishes the new state before deallocating the old instance")
    func removePublishesBeforeDealloc() async throws {
        let grace: TimeInterval = 0.15
        let factory = StubFactory()
        let plugin = makeConfig(name: "Doomed")
        let chain = makeChain(plugins: [plugin], factory: factory, grace: grace)
        let host = FakeHost()

        chain.attach(to: host, sampleRate: 48000)
        await chain.waitForPendingWork()
        #expect(chain.slots[0].state == .ready)

        chain.removePlugin(id: plugin.id)
        #expect(chain.slots.isEmpty)
        #expect((host.published.last ?? nil) == nil)
        let nilPublishedAt = try #require(host.lastNilPublishTime)

        let log = factory.made[0].log
        await waitUntil("the deallocation to land") { log.events.contains(.deallocate) }
        let deallocatedAt = try #require(log.firstTime(of: .deallocate))
        #expect(deallocatedAt.timeIntervalSince(nilPublishedAt) >= grace)
    }
}

// MARK: - Manager

@Suite("AUChainManager — default-chain fork semantics")
@MainActor
struct AUChainManagerTests {

    private func makeSettings() throws -> SettingsManager {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsManager(directory: directory)
    }

    @Test("An app with no key follows the default chain but gets its own instances")
    func followsDefaultWithOwnInstances() async throws {
        let settings = try makeSettings()
        settings.defaultAUChain = AUChainConfig(plugins: [makeConfig(name: "Shared By Default")])
        let factory = StubFactory()
        let manager = AUChainManager(settingsManager: settings, factory: factory)

        manager.attach(to: FakeHost(), identifier: "app.one", sampleRate: 48000, appName: "One")
        manager.attach(to: FakeHost(), identifier: "app.two", sampleRate: 48000, appName: "Two")

        await manager.chain(for: "app.one")?.waitForPendingWork()
        await manager.chain(for: "app.two")?.waitForPendingWork()
        #expect(manager.chain(for: "app.one")?.slots.first?.state == .ready)
        #expect(manager.chain(for: "app.two")?.slots.first?.state == .ready)
        #expect(manager.chain(for: "app.one")?.followsDefault == true)
        // Two apps, two separate instances — never shared across taps (§4).
        #expect(factory.made.count == 2)
    }

    @Test("The first structural edit forks the app onto its own chain")
    func structuralEditForks() async throws {
        let settings = try makeSettings()
        settings.defaultAUChain = AUChainConfig(plugins: [makeConfig(name: "Default Effect")])
        let manager = AUChainManager(settingsManager: settings, factory: StubFactory())

        manager.attach(to: FakeHost(), identifier: "app.one", sampleRate: 48000)
        let chain = try #require(manager.chain(for: "app.one"))
        #expect(chain.followsDefault)
        #expect(settings.getAUChain(for: "app.one") == nil)

        chain.addPlugin(makeConfig(name: "Extra Effect"))

        #expect(!chain.followsDefault)
        #expect(settings.getAUChain(for: "app.one")?.plugins.count == 2)
        // The default is untouched by the fork.
        #expect(settings.defaultAUChain?.plugins.count == 1)
    }

    @Test("A parameter capture on a default-chain instance writes back to the default")
    func captureWritesBackToDefault() async throws {
        let settings = try makeSettings()
        settings.defaultAUChain = AUChainConfig(plugins: [makeConfig(name: "Default Effect")])
        let factory = StubFactory()
        let manager = AUChainManager(settingsManager: settings, factory: factory)

        manager.attach(to: FakeHost(), identifier: "app.one", sampleRate: 48000)
        let chain = try #require(manager.chain(for: "app.one"))
        await chain.waitForPendingWork()
        #expect(chain.slots.first?.state == .ready)

        chain.flushSync()

        #expect(settings.defaultAUChain?.plugins.first?.fullState == Data([0xAB, 0xCD]))
        // No fork: a parameter tweak is not a structural edit (§4).
        #expect(chain.followsDefault)
        #expect(settings.getAUChain(for: "app.one") == nil)
    }

    @Test("An explicitly empty chain is not the same as following the default")
    func emptyChainIsNotDefault() throws {
        let settings = try makeSettings()
        settings.defaultAUChain = AUChainConfig(plugins: [makeConfig(name: "Default Effect")])
        settings.setAUChain(AUChainConfig(plugins: []), for: "app.silent")
        let factory = StubFactory()
        let manager = AUChainManager(settingsManager: settings, factory: factory)

        manager.attach(to: FakeHost(), identifier: "app.silent", sampleRate: 48000)

        // Nothing to host, so no chain and no instances (§4 absence-vs-empty).
        #expect(manager.chain(for: "app.silent") == nil)
        #expect(factory.made.isEmpty)
    }
}
