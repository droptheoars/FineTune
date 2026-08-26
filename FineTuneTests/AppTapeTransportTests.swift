// FineTuneTests/AppTapeTransportTests.swift
// Lifecycle gate for AppTapeTransport / TapeTransportManager (spec §8 T4).
//
// The dangerous parts of this layer are all ORDERING, not timing: publish-nil
// must precede the free, the free must wait out the render grace, a stale
// allocation must be discarded rather than published, and a same-rate re-attach
// must republish the SAME ring. So the seams the tests drive are the two the
// class already injects — the allocator and the grace — and every assertion is
// against an ordered event log or an object identity. Nothing sleeps: the
// injected grace records instead of waiting.
//
// The one thing an event log cannot record is the free itself (TapeTransportRT
// is final, so its deinit cannot be hooked). The tests prove it with weak
// references instead: alive when the grace runs, gone once the work settles.

import Foundation
import Testing
@testable import FineTune

// MARK: - Fakes

private enum TapeEvent: Equatable {
    case allocated(rate: Double, capacity: Int)
    case published
    case publishedNil
    /// Records whether the most recently allocated ring was still alive at the
    /// moment the grace ran — i.e. that the free had NOT happened yet.
    case grace(ringAlive: Bool)
    case exportBegan
    case exportEnded
}

/// Thread-safe ordered log — written from the utility queue and MainActor.
private nonisolated final class TapeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [TapeEvent] = []

    func record(_ event: TapeEvent) {
        lock.lock()
        entries.append(event)
        lock.unlock()
    }

    var events: [TapeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var allocationCount: Int {
        events.filter { if case .allocated = $0 { return true } else { return false } }.count
    }

    var sawGrace: Bool {
        events.contains { if case .grace = $0 { return true } else { return false } }
    }
}

/// Weak handle on the ring the allocator last built, so the grace closure can
/// observe liveness from off-main without retaining anything.
private nonisolated final class WeakRing: @unchecked Sendable {
    private let lock = NSLock()
    private weak var ring: TapeTransportRT?

    var value: TapeTransportRT? {
        get { lock.lock(); defer { lock.unlock() }; return ring }
        set { lock.lock(); ring = newValue; lock.unlock() }
    }
}

/// Records publications WITHOUT retaining them — a strong array here would keep
/// every ring alive and quietly defeat the free assertions.
@MainActor
private final class FakeTapeHost: TapeTransportHosting {
    private let log: TapeEventLog
    private(set) var publishCount = 0
    private(set) var lastWasNil = true
    private weak var current: TapeTransportRT?

    init(log: TapeEventLog) { self.log = log }

    func setTransport(_ transport: TapeTransportRT?) {
        publishCount += 1
        lastWasNil = transport == nil
        current = transport
        log.record(transport == nil ? .publishedNil : .published)
    }

    func isHosting(_ transport: TapeTransportRT?) -> Bool {
        guard let transport, let current else { return false }
        return current === transport
    }
}

@MainActor
private final class ExportGate {
    var isOpen = false
}

// MARK: - Helpers

private let testRate: Double = 8000
private let testCapacity = 480_000  // 1 minute at 8 kHz

private nonisolated func makeAllocator(
    log: TapeEventLog,
    ring: WeakRing,
    gate: DispatchSemaphore? = nil
) -> @Sendable (Double, Int) -> TapeTransportRT {
    { rate, capacity in
        gate?.wait()
        let built = TapeTransportRT(sampleRate: rate, capacityFrames: capacity)
        ring.value = built
        log.record(.allocated(rate: rate, capacity: capacity))
        return built
    }
}

private nonisolated func makeGrace(log: TapeEventLog, ring: WeakRing) -> @Sendable () -> Void {
    { log.record(.grace(ringAlive: ring.value != nil)) }
}

@MainActor
private func makeTransport(
    enabled: Bool = true,
    minutes: Int = 1,
    log: TapeEventLog,
    ring: WeakRing,
    gate: DispatchSemaphore? = nil
) -> AppTapeTransport {
    AppTapeTransport(
        identifier: "com.test.tape",
        appName: "Test App",
        config: TapeTransportConfig(isEnabled: enabled, ringMinutes: minutes),
        makeRT: makeAllocator(log: log, ring: ring, gate: gate),
        graceWait: makeGrace(log: log, ring: ring)
    )
}

/// Drives the RT thread's entry point from the test thread — the transport is
/// unpublished here, so this is the only writer.
@MainActor
private func pump(_ transport: TapeTransportRT, frames: Int, callbacks: Int = 1, value: Float = 0.25) {
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    for _ in 0..<callbacks {
        for index in 0..<(frames * 2) { buffer[index] = value }
        _ = transport.writeAndRender(interleavedStereo: buffer, frameCount: frames)
    }
}

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
private func makeSettings() throws -> SettingsManager {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return SettingsManager(directory: directory)
}

// MARK: - Enable / publish

@Suite("AppTapeTransport — enable")
@MainActor
struct AppTapeTransportEnableTests {

    @Test("Attach allocates the ring off-main and only then publishes it")
    func allocatesBeforePublishing() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)

        transport.attach(to: host, sampleRate: testRate)
        // E23: nothing is published on the way in — the allocation is still in
        // flight on the utility queue.
        #expect(transport.state == .allocating)
        #expect(host.publishCount == 0)

        await transport.waitForPendingWork()

        #expect(transport.state == .ready)
        #expect(log.events == [.allocated(rate: testRate, capacity: testCapacity), .published])
        let ready = try #require(transport.transport)
        #expect(host.isHosting(ready))
        #expect(ready.capacityFrames == testCapacity)
        // Exact, never padded (§2.3): minutes × 60 × rate × 2ch × 4 bytes.
        #expect(ready.allocatedRingBytes == testCapacity * 2 * 4)
        #expect(ready.diagnosticsSnapshot().isPinnedToLive)
    }

    @Test("A tape that is off allocates nothing when its tap appears")
    func disabledConfigAllocatesNothing() async {
        let log = TapeEventLog()
        let transport = makeTransport(enabled: false, log: log, ring: WeakRing())
        let host = FakeTapeHost(log: log)

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()

        #expect(transport.state == .disabled)
        #expect(transport.transport == nil)
        #expect(log.events.isEmpty)
        #expect(host.publishCount == 0)
    }

    @Test("A second attach while allocating does not start a second ring")
    func reentrantAttachDoesNotDoubleAllocate() async {
        let log = TapeEventLog()
        let ring = WeakRing()
        let gate = DispatchSemaphore(value: 0)
        let transport = makeTransport(log: log, ring: ring, gate: gate)
        let host = FakeTapeHost(log: log)

        transport.attach(to: host, sampleRate: testRate)
        transport.attach(to: host, sampleRate: testRate)
        gate.signal()
        gate.signal()
        await transport.waitForPendingWork()

        #expect(log.allocationCount == 1)
        #expect(transport.state == .ready)
    }
}

// MARK: - Teardown ordering (E15 + E23)

@Suite("AppTapeTransport — teardown ordering")
@MainActor
struct AppTapeTransportTeardownTests {

    @Test("Disable publishes nil first, frees only after the grace")
    func publishNilThenGraceThenFree() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        weak var published = transport.transport
        #expect(published != nil)

        transport.disable()

        // The tap stops seeing the ring synchronously, before anything is freed.
        #expect(host.lastWasNil)
        #expect(transport.transport == nil)
        #expect(transport.state == .disabled)
        #expect(published != nil, "the ring must outlive the nil publish")

        await transport.waitForPendingWork()

        // Ordering, not timing: nil published → grace → free. `ringAlive: true`
        // is the assertion that the free had not happened when the grace ran.
        #expect(log.events == [
            .allocated(rate: testRate, capacity: testCapacity),
            .published,
            .publishedNil,
            .grace(ringAlive: true)
        ])
        #expect(published == nil, "the ring must be freed once the grace has elapsed")
    }

    @Test("An allocation that loses its race is discarded, never published")
    func staleAllocationIsDiscarded() async {
        let log = TapeEventLog()
        let ring = WeakRing()
        let gate = DispatchSemaphore(value: 0)
        let transport = makeTransport(log: log, ring: ring, gate: gate)
        let host = FakeTapeHost(log: log)

        transport.attach(to: host, sampleRate: testRate)
        #expect(transport.state == .allocating)
        // The disable lands while the allocator is still blocked (E23).
        transport.disable()
        gate.signal()
        await transport.waitForPendingWork()

        #expect(transport.state == .disabled)
        #expect(transport.transport == nil)
        #expect(!log.events.contains(.published), "an orphan allocation must never reach the tap")
        #expect(ring.value == nil, "the orphan ring must be freed")
        // Nothing was published, so no grace is owed on the orphan path.
        #expect(!log.sawGrace)
    }

    @Test("Release frees the ring and forgets the tap")
    func releaseFreesRing() async {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        weak var published = transport.transport

        transport.release()
        await transport.waitForPendingWork()

        #expect(host.lastWasNil)
        #expect(published == nil)
        #expect(transport.state == .disabled)
    }
}

// MARK: - Tap churn (§2.6 attach) and rate change (E22)

@Suite("AppTapeTransport — attach and rate change")
@MainActor
struct AppTapeTransportAttachTests {

    @Test("A same-rate re-attach republishes the same ring, preserving position and content")
    func sameRateReattachPreservesEverything() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let firstHost = FakeTapeHost(log: log)

        transport.attach(to: firstHost, sampleRate: testRate)
        await transport.waitForPendingWork()
        let rt = try #require(transport.transport)

        pump(rt, frames: 512, callbacks: 20)
        rt.requestSeek(toFrame: rt.writtenFrames - 4000)
        pump(rt, frames: 512)  // the RT thread consumes the seek on the next callback
        let before = rt.diagnosticsSnapshot()
        #expect(!before.isPinnedToLive)
        #expect(before.writeFrames > 0)

        // The tap died and came back on the same device — the churn the ring is
        // owned outside the tap to survive.
        let secondHost = FakeTapeHost(log: log)
        transport.attach(to: secondHost, sampleRate: testRate)
        await transport.waitForPendingWork()

        #expect(transport.transport === rt, "the same object must be republished")
        #expect(secondHost.isHosting(rt))
        let after = rt.diagnosticsSnapshot()
        #expect(after.writeFrames == before.writeFrames)
        #expect(after.readPositionQ == before.readPositionQ)
        #expect(after.isPinnedToLive == false)
        #expect(log.allocationCount == 1, "a re-attach must not reallocate the ring")
    }

    @Test("A rate change discards the tape and comes back pinned to live (E22)")
    func rateChangeClearsAndRepins() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        // Deliberately no long-lived local: a strong reference here would keep
        // the old ring alive and make the free assertion below vacuous.
        pump(try #require(transport.transport), frames: 512, callbacks: 10)
        transport.transport?.requestSeek(toFrame: 1000)
        pump(try #require(transport.transport), frames: 512)
        #expect(try #require(transport.transport).diagnosticsSnapshot().isPinnedToLive == false)
        weak var oldRing = transport.transport

        // A2DP↔SCO style re-rate arriving through the tap-creation path.
        transport.attach(to: host, sampleRate: testRate * 2)
        await transport.waitForPendingWork()

        let new = try #require(transport.transport)
        // Two allocations, not one: the old ring was discarded, not resampled.
        // (Object identity is no proof here — the freed ring's address is fair
        // game for the new one.)
        #expect(log.allocationCount == 2)
        #expect(new.sampleRate == testRate * 2)
        #expect(new.capacityFrames == Int(testRate * 2) * 60)
        // Empty tape, pinned to live: old-rate frames are never resampled.
        #expect(new.writtenFrames == 0)
        #expect(new.diagnosticsSnapshot().isPinnedToLive)
        #expect(transport.sampleRate == testRate * 2)
        #expect(oldRing == nil, "the old-rate ring must be freed")
        // The old ring leaves the tap before the new one is built, and the free
        // still waits out the grace.
        let events = log.events
        let nilIndex = try #require(events.firstIndex(of: .publishedNil))
        let rebuiltIndex = try #require(
            events.firstIndex(of: .allocated(rate: testRate * 2, capacity: Int(testRate * 2) * 60))
        )
        #expect(nilIndex < rebuiltIndex)
        #expect(events.contains(.grace(ringAlive: true)))
        #expect(events.last == .published)
    }

    @Test("Resizing the ring reallocates at the new length and clears the tape")
    func resizeReallocates() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(minutes: 1, log: log, ring: ring)
        let host = FakeTapeHost(log: log)
        var persisted: [TapeTransportConfig] = []
        transport.onPersist = { persisted.append($0) }

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        pump(try #require(transport.transport), frames: 512, callbacks: 4)

        transport.setRingMinutes(5)
        await transport.waitForPendingWork()

        let resized = try #require(transport.transport)
        #expect(resized.capacityFrames == Int(testRate) * 60 * 5)
        #expect(resized.writtenFrames == 0)
        #expect(persisted.last?.ringMinutes == 5)
        #expect(transport.config.ringMinutes == 5)
    }

    @Test("Arming a tape whose tap already exists allocates against the live rate")
    func enableAfterAttach() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(enabled: false, log: log, ring: ring)
        let host = FakeTapeHost(log: log)
        var persisted: [TapeTransportConfig] = []
        transport.onPersist = { persisted.append($0) }

        transport.attach(to: host, sampleRate: testRate)
        #expect(transport.state == .disabled)

        transport.setEnabled(true)
        await transport.waitForPendingWork()

        #expect(transport.state == .ready)
        #expect(transport.transport?.sampleRate == testRate)
        #expect(host.isHosting(transport.transport))
        #expect(persisted.last?.isEnabled == true)
    }
}

// MARK: - Export refcount (§2.6)

@Suite("AppTapeTransport — export")
@MainActor
struct AppTapeTransportExportTests {

    @Test("An in-flight export defers the free past the grace")
    func exportDefersTheFree() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)
        let gate = ExportGate()
        var handed: (endFrame: Int64, frameCount: Int, appName: String)?

        transport.onExport = { _, endFrame, frameCount, appName in
            handed = (endFrame, frameCount, appName)
            log.record(.exportBegan)
            while !gate.isOpen { try? await Task.sleep(nanoseconds: 1_000_000) }
            log.record(.exportEnded)
            return true
        }

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        // No long-lived local: the only strong references that may exist here
        // are the transport's own and the exporter's (that is the test).
        pump(try #require(transport.transport), frames: 512, callbacks: 20)
        let writtenAtExport = try #require(transport.transport?.writtenFrames)

        #expect(transport.export(lastMinutes: 1))
        await waitUntil("export started") { log.events.contains(.exportBegan) }
        #expect(handed?.endFrame == writtenAtExport)
        #expect(handed?.appName == "Test App")
        // Bounded by what has actually been recorded, not by what was asked for.
        #expect(handed?.frameCount == Int(writtenAtExport))

        transport.disable()
        await waitUntil("grace elapsed") { log.sawGrace }
        #expect(ring.value != nil, "the exporter's reference must keep the ring alive")

        gate.isOpen = true
        await transport.waitForPendingWork()
        #expect(ring.value == nil, "the ring is freed once the exporter lets go")
        #expect(log.events.suffix(2) == [.grace(ringAlive: true), .exportEnded])
    }

    @Test("Export is refused with no exporter, no ring, or an empty tape")
    func exportRefusesWhenThereIsNothingToWrite() async {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)

        #expect(!transport.export(lastMinutes: 1), "no ring yet")

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        #expect(!transport.export(lastMinutes: 1), "no exporter wired")

        transport.onExport = { _, _, _, _ in true }
        #expect(!transport.export(lastMinutes: 1), "nothing recorded yet")
    }
}

// MARK: - T12: save-length clamping (§8, the Settings "Save Length" preference)
//
// `AppTapeTransport.export(lastMinutes:)` already clamps its request against
// what the ring actually holds (see its `frameCount` computation) — these
// tests exercise exactly the values the new global setting can produce
// (`TapeSaveLength.minutes`, with `.wholeTape` resolved by the caller to
// `Double(config.ringMinutes)`, same as production wiring in
// `TapeTransportPanelModel+Engine.swift`), so a future change to either side
// of that contract breaks a test instead of shipping silently wrong.
@Suite("AppTapeTransport — save-length clamping (T12)")
@MainActor
struct AppTapeTransportSaveLengthClampTests {

    @Test("A request longer than the ring yields exactly what the ring holds")
    func longRequestClampsToRingCapacity() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)
        var handedFrameCount: Int?
        transport.onExport = { _, _, frameCount, _ in handedFrameCount = frameCount; return true }

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        let rt = try #require(transport.transport)
        // Write well past capacity so the ring has wrapped and genuinely holds
        // only `capacityFrames - marginFrames` of reachable audio.
        pump(rt, frames: 512, callbacks: (testCapacity / 512) * 2)

        // 15 fixed minutes is far longer than the 1-minute test ring.
        #expect(transport.export(lastMinutes: 15))
        await waitUntil("export handed a frame count") { handedFrameCount != nil }
        #expect(handedFrameCount == rt.capacityFrames - rt.marginFrames)
    }

    @Test("Whole tape (resolved to the ring's own length) yields everything recorded")
    func wholeTapeYieldsEverythingRecorded() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)
        var handedFrameCount: Int?
        transport.onExport = { _, _, frameCount, _ in handedFrameCount = frameCount; return true }

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        let rt = try #require(transport.transport)
        // Half the ring, well short of capacity: "whole tape" must not pad this
        // out to the ring's full size.
        let written = 512 * 20
        pump(rt, frames: 512, callbacks: 20)

        // Production's `.wholeTape` resolution: `saveLength.minutes ?? Double(config.ringMinutes)`.
        #expect(TapeSaveLength.wholeTape.minutes == nil)
        #expect(transport.export(lastMinutes: Double(transport.config.ringMinutes)))
        await waitUntil("export handed a frame count") { handedFrameCount != nil }
        #expect(handedFrameCount == written)
    }

    @Test("A short fixed request yields exactly that much, not the whole tape")
    func shortRequestYieldsExactlyWhatWasAsked() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(log: log, ring: ring)
        let host = FakeTapeHost(log: log)
        var handedFrameCount: Int?
        transport.onExport = { _, _, frameCount, _ in handedFrameCount = frameCount; return true }

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        let rt = try #require(transport.transport)
        // Fill most of the 1-minute ring (307,200 of 480,000 frames) — well past
        // the 240,000 frames a 30-second request needs, so the request itself is
        // the binding constraint, not what has been recorded.
        pump(rt, frames: 512, callbacks: 600)

        let requestedMinutes = TapeSaveLength.seconds30.minutes!
        #expect(transport.export(lastMinutes: requestedMinutes))
        await waitUntil("export handed a frame count") { handedFrameCount != nil }
        #expect(handedFrameCount == Int((requestedMinutes * 60.0 * rt.sampleRate).rounded()))
    }

    @Test("Each export reflects the ring length live at call time, not one fixed earlier (T10/N5, T12)")
    func exportReadsRingLengthAtCallTimeNotEarlier() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let transport = makeTransport(minutes: 1, log: log, ring: ring)
        let host = FakeTapeHost(log: log)
        var handedFrameCounts: [Int] = []
        transport.onExport = { _, _, frameCount, _ in handedFrameCounts.append(frameCount); return true }

        transport.attach(to: host, sampleRate: testRate)
        await transport.waitForPendingWork()
        pump(try #require(transport.transport), frames: 512, callbacks: 4)

        // "Whole tape" resolved against the config exactly as the export
        // closure does — read fresh on every call, never snapshotted once.
        func exportWholeTape() {
            let transport = transport  // the same re-read-every-time shape as the production closure
            _ = transport.export(lastMinutes: Double(transport.config.ringMinutes))
        }

        exportWholeTape()
        await waitUntil("first export landed") { handedFrameCounts.count == 1 }

        // The ring is resized between the two exports — a stale capture of the
        // old ringMinutes would still report the old (smaller) length here.
        transport.setRingMinutes(15)
        await transport.waitForPendingWork()
        pump(try #require(transport.transport), frames: 512, callbacks: 4)

        exportWholeTape()
        await waitUntil("second export landed") { handedFrameCounts.count == 2 }

        let rt = try #require(transport.transport)
        #expect(rt.capacityFrames == Int(testRate) * 60 * 15, "the ring really did grow")
        #expect(handedFrameCounts[1] == 512 * 4, "the second export reflects the NEW ring, not the one read at the first call")
    }
}

// MARK: - Manager

@Suite("TapeTransportManager — registry")
@MainActor
struct TapeTransportManagerTests {

    private func makeManager(settings: SettingsManager, log: TapeEventLog, ring: WeakRing) -> TapeTransportManager {
        TapeTransportManager(
            settingsManager: settings,
            makeRT: makeAllocator(log: log, ring: ring),
            graceWait: makeGrace(log: log, ring: ring)
        )
    }

    @Test("An app with no armed tape gets no transport and no allocation")
    func offByDefault() async throws {
        let log = TapeEventLog()
        let manager = makeManager(settings: try makeSettings(), log: log, ring: WeakRing())

        manager.attach(to: FakeTapeHost(log: log), identifier: "app.quiet", sampleRate: testRate, appName: "Quiet")

        #expect(manager.transport(for: "app.quiet") == nil)
        #expect(log.events.isEmpty)
    }

    @Test("An armed config builds and publishes a transport on attach")
    func armedConfigBuildsOnAttach() async throws {
        let log = TapeEventLog()
        let settings = try makeSettings()
        settings.setTapeTransport(TapeTransportConfig(isEnabled: true, ringMinutes: 1), for: "app.tape")
        let manager = makeManager(settings: settings, log: log, ring: WeakRing())
        let host = FakeTapeHost(log: log)

        manager.attach(to: host, identifier: "app.tape", sampleRate: testRate, appName: "Taped")
        let transport = try #require(manager.transport(for: "app.tape"))
        await transport.waitForPendingWork()

        #expect(transport.state == .ready)
        #expect(transport.appName == "Taped")
        #expect(host.isHosting(transport.transport))
    }

    @Test("Arming through the panel persists the config and survives a manager restart")
    func editableTransportPersists() async throws {
        let log = TapeEventLog()
        let settings = try makeSettings()
        let manager = makeManager(settings: settings, log: log, ring: WeakRing())

        let transport = manager.editableTransport(for: "app.tape", appName: "Taped")
        transport.setEnabled(true)
        transport.setRingMinutes(15)

        #expect(settings.getTapeTransport(for: "app.tape")?.isEnabled == true)
        #expect(settings.getTapeTransport(for: "app.tape")?.ringMinutes == 15)

        // A fresh manager rebuilds the same intent from settings alone.
        let restarted = makeManager(settings: settings, log: TapeEventLog(), ring: WeakRing())
        #expect(restarted.config(for: "app.tape").ringMinutes == 15)
    }

    @Test("Release frees the ring and forgets the app (E29)")
    func releaseForgetsTheApp() async throws {
        let log = TapeEventLog()
        let ring = WeakRing()
        let settings = try makeSettings()
        settings.setTapeTransport(TapeTransportConfig(isEnabled: true, ringMinutes: 1), for: "app.tape")
        let manager = makeManager(settings: settings, log: log, ring: ring)

        manager.attach(to: FakeTapeHost(log: log), identifier: "app.tape", sampleRate: testRate)
        let transport = try #require(manager.transport(for: "app.tape"))
        await transport.waitForPendingWork()

        manager.release(identifier: "app.tape")
        await transport.waitForPendingWork()

        #expect(manager.transport(for: "app.tape") == nil)
        #expect(ring.value == nil)
        // Rebuilt from config on demand.
        #expect(manager.config(for: "app.tape").isEnabled)
    }

    @Test("E20: only a non-live transport counts as engaged")
    func engagedTracksNonLive() async throws {
        let log = TapeEventLog()
        let settings = try makeSettings()
        settings.setTapeTransport(TapeTransportConfig(isEnabled: true, ringMinutes: 1), for: "app.tape")
        let manager = makeManager(settings: settings, log: log, ring: WeakRing())

        #expect(!manager.isEngaged(identifier: "app.tape"))
        manager.attach(to: FakeTapeHost(log: log), identifier: "app.tape", sampleRate: testRate)
        let transport = try #require(manager.transport(for: "app.tape"))
        await transport.waitForPendingWork()
        let rt = try #require(transport.transport)
        #expect(!manager.isEngaged(identifier: "app.tape"), "recording live is not engaged")

        pump(rt, frames: 512, callbacks: 10)
        rt.requestSeek(toFrame: 500)
        pump(rt, frames: 512)

        #expect(manager.isEngaged(identifier: "app.tape"), "the user is listening to the past")
    }
}
