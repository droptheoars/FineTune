// FineTuneTests/AudioEngineTapeLifecycleTests.swift
//
// Engine-level rulings about a tape whose app has gone quiet (T10 review):
//
//   C2 — stale-tap cleanup keeps an ARMED tape's ring. A pause is not a quit,
//        and freeing the ring on a pause is silent data loss on the flagship
//        "save what just happened" flow.
//   I1 — an ENGAGED tape keeps its app in the displayed list, because LIVE,
//        stop and scrub only exist on the app's row.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - A tap the tape layer can bind to

/// Minimal `ProcessTapControlling` that also hosts the two render layers, so the
/// engine's `attachRenderLayers` actually attaches. Records nothing the tests do
/// not assert on: the published transport pointer and whether it was invalidated.
@MainActor
final class TapeHostingTapStub: ProcessTapControlling, AUChainHosting, TapeTransportHosting {
    let app: AudioApp
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0.0
    var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil

    private(set) var isInvalidated = false
    private(set) var publishedTransport: TapeTransportRT?

    let nominalSampleRate: Double? = 48_000

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func setAUChain(_ state: AUChainRenderState?) {}
    func setTransport(_ transport: TapeTransportRT?) { publishedTransport = transport }

    func activate(initial: TapInitialState) throws {}
    func invalidate() { isInvalidated = true }
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = [newDeviceUID]
    }
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }
    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }
}

// MARK: - Fixture

@MainActor
private final class TapBoxTape {
    var last: TapeHostingTapStub?
}

@MainActor
private struct TapeFixture {
    let engine: AudioEngine
    let processMonitor: StubProcessMonitor
    let app: AudioApp
    let device: AudioDevice
    let tap: () -> TapeHostingTapStub?

    var identifier: String { app.persistenceIdentifier }

    /// Arms a 1-minute tape on the live tap and returns it with its ring allocated.
    /// Mirrors the UI's order exactly: the tap exists, the panel asks for an
    /// editable transport (which attaches it), then the switch arms it.
    func armTape() async -> AppTapeTransport {
        let transport = engine.editableTapeTransport(for: identifier, appName: app.name)
        transport.setRingMinutes(1)
        transport.setEnabled(true)
        await transport.waitForPendingWork()
        return transport
    }

    /// Records `callbacks` HAL callbacks of audible audio into the ring.
    func record(into transport: AppTapeTransport, callbacks: Int = 8) {
        guard let ring = transport.transport else {
            Issue.record("the tape must have a ring to record into")
            return
        }
        let frames = 512
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { scratch.deallocate() }
        for _ in 0..<callbacks {
            scratch.update(repeating: 0.5, count: frames * 2)
            _ = ring.writeAndRender(interleavedStereo: scratch, frameCount: frames)
        }
    }

    /// The app stops making sound. Fires the same callback the process monitor does.
    func appGoesQuiet() {
        processMonitor.activeApps = []
        processMonitor.onAppsChanged?([])
    }

    /// Waits for the stale sweep to invalidate the tap (ordering, not timing: the
    /// sweep's own delay is injected at 1 ms).
    func waitForStaleCleanup() async {
        for _ in 0..<400 {
            if tap()?.isInvalidated == true { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the stale sweep never ran")
    }
}

@MainActor
private func makeTapeFixture(processAlive: Bool = true) -> TapeFixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-tape",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: false
    )
    deviceMonitor.addOutputDevice(device)
    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = 0.75

    let app = AudioApp(
        id: 4242,
        processObjectIDs: [],
        name: "TapeApp",
        icon: NSImage(),
        bundleID: "com.test.tape"
    )
    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    let box = TapBoxTape()
    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = TapeHostingTapStub(app: app, deviceUIDs: uids)
            box.last = tap
            return tap
        },
        isAlive: { _ in true },
        isProcessAlive: { _ in processAlive },
        staleCleanupDelay: .milliseconds(1),
        startMonitorsAutomatically: false
    )
    engine.setDevice(for: app, deviceUID: device.uid)

    return TapeFixture(
        engine: engine,
        processMonitor: processMonitor,
        app: app,
        device: device,
        tap: { box.last }
    )
}

// MARK: - C2

@Suite("AudioEngine — a paused app keeps its armed tape (C2)")
@MainActor
struct AudioEngineStaleTapeCleanupTests {

    @Test("An armed tape survives the stale sweep with its recording intact")
    func armedTapeSurvivesAPause() async {
        let fix = makeTapeFixture()
        let tape = await fix.armTape()
        fix.record(into: tape)
        let recorded = tape.transport?.writtenFrames ?? 0
        #expect(recorded > 0, "the tape must hold audio before the app pauses")

        fix.appGoesQuiet()
        await fix.waitForStaleCleanup()

        let kept = fix.engine.tapeTransportManager.transport(for: fix.identifier)
        #expect(kept === tape, "the sweep must free the tap, not the tape")
        #expect(kept?.transport != nil, "releasing the ring is silent data loss (C2)")
        #expect(kept?.transport?.writtenFrames == recorded,
                "the recording must still be there when the user comes back")
    }

    @Test("A disarmed tape is still forgotten by the stale sweep")
    func disarmedTapeIsStillReleased() async {
        let fix = makeTapeFixture()
        // Created by the panel but never armed — nothing to lose, nothing to keep.
        _ = fix.engine.editableTapeTransport(for: fix.identifier, appName: fix.app.name)
        #expect(fix.engine.tapeTransportManager.transport(for: fix.identifier) != nil)

        fix.appGoesQuiet()
        await fix.waitForStaleCleanup()

        #expect(fix.engine.tapeTransportManager.transport(for: fix.identifier) == nil,
                "a disarmed transport has no reason to outlive its tap")
    }

    @Test("Quitting the app frees the ring even when the tape is armed")
    func quitFreesTheRing() async {
        let fix = makeTapeFixture(processAlive: false)
        let tape = await fix.armTape()
        fix.record(into: tape)

        fix.appGoesQuiet()
        await fix.waitForStaleCleanup()

        #expect(fix.engine.tapeTransportManager.transport(for: fix.identifier) == nil,
                "a dead process is the one case that must free up to 346 MB")
    }

    @Test("Hiding the app frees the ring even when the tape is armed")
    func ignoreFreesTheRing() async {
        let fix = makeTapeFixture()
        let tape = await fix.armTape()
        fix.record(into: tape)

        fix.engine.ignoreApp(fix.app)

        #expect(fix.engine.tapeTransportManager.transport(for: fix.identifier) == nil,
                "an ignored app is gone by the user's own instruction")
    }
}

// MARK: - I1

@Suite("AudioEngine — an engaged tape stays reachable (I1)")
@MainActor
struct AudioEngineEngagedTapeVisibilityTests {

    /// Rewinds the tape and runs one more callback so the RT thread consumes the
    /// seek — engagement is a fact about the render thread, not about the request.
    private func engage(_ tape: AppTapeTransport) {
        guard let ring = tape.transport else {
            Issue.record("no ring to rewind")
            return
        }
        ring.requestSeek(toFrame: max(0, ring.writtenFrames - 2048))
        let frames = 512
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { scratch.deallocate() }
        scratch.update(repeating: 0, count: frames * 2)
        _ = ring.writeAndRender(interleavedStereo: scratch, frameCount: frames)
    }

    @Test("A quiet app playing the past keeps its row")
    func engagedQuietAppStaysListed() async {
        let fix = makeTapeFixture()
        let tape = await fix.armTape()
        fix.record(into: tape)
        engage(tape)
        #expect(tape.transport?.diagnosticsSnapshot().isPinnedToLive == false,
                "the tape must actually be playing the past")

        // The app goes quiet. Its tap survives (E20) and audio keeps coming out.
        fix.processMonitor.activeApps = []

        let listed = fix.engine.displayableApps
        #expect(listed.contains { $0.id == fix.identifier },
                "ghost audio with no LIVE button and no stop is not acceptable (I1)")
        #expect(listed.first { $0.id == fix.identifier }?.isActive == true,
                "it must land on the row that carries the transport strip")
    }

    @Test("A quiet app sitting at live does not keep its row")
    func liveQuietAppIsNotListed() async {
        let fix = makeTapeFixture()
        let tape = await fix.armTape()
        fix.record(into: tape)
        #expect(tape.transport?.diagnosticsSnapshot().isPinnedToLive == true)

        fix.processMonitor.activeApps = []

        #expect(fix.engine.displayableApps.isEmpty,
                "an armed but live tape is nothing to see — unchanged behaviour")
    }
}
