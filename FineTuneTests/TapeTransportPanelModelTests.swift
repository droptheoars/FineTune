// FineTuneTests/TapeTransportPanelModelTests.swift
// T9: the wiring between the transport engine and the strip — engine state in,
// view state out, and the commands the buttons send back.
//
// The §5 state -> label table is already covered by TapeTransportStripTests
// against hand-built models. What is NOT covered there, and is what this file
// exists for, is whether a REAL transport produces those models: a scrub really
// lands the model behind live, a loop really drifts with the tape, a failed
// export really does not show a tick. So these tests drive an actual
// TapeTransportRT and pump its RT entry point from the test thread — the ring is
// unpublished here, so the test is the only writer and there is no timing to
// depend on. Nothing sleeps; the release grace is injected away.
//
// The one thing deliberately NOT asserted is the E18 horizon: reaching it means
// filling a whole ring, and TapeTransportRTTests already owns that behaviour.

import Foundation
import Testing
@testable import FineTune

// MARK: - Helpers

// A deliberately low synthetic rate: the code is rate-agnostic, and every test
// here blocks MainActor while it pumps, so a 1-minute ring costs 48_000 frames
// instead of 480_000. Tests that share this process have deadlines.
private let testRate: Double = 800
private let frames = 512

@MainActor
private final class FakeTapeHost: TapeTransportHosting {
    private(set) var published: TapeTransportRT?
    func setTransport(_ transport: TapeTransportRT?) { published = transport }
}

@MainActor
private final class ExportGate {
    var isOpen = false
    var result = true
}

@MainActor
private func makeArmedTransport(minutes: Int = 1, rate: Double = testRate) async -> (AppTapeTransport, FakeTapeHost) {
    let transport = AppTapeTransport(
        identifier: "com.test.tape.ui",
        appName: "Test App",
        config: TapeTransportConfig(isEnabled: true, ringMinutes: minutes),
        graceWait: {}
    )
    let host = FakeTapeHost()
    transport.attach(to: host, sampleRate: rate)
    await transport.waitForPendingWork()
    return (transport, host)
}

/// Drives the RT entry point from the test thread — the ring is unpublished, so
/// this is the only writer.
@MainActor
private func pump(_ transport: AppTapeTransport, callbacks: Int, value: Float = 0.25) {
    guard let ring = transport.transport else { return }
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    for _ in 0..<callbacks {
        for index in 0..<(frames * 2) { buffer[index] = value }
        _ = ring.writeAndRender(interleavedStereo: buffer, frameCount: frames)
    }
}

@MainActor
private func model(_ transport: AppTapeTransport?, config: TapeTransportConfig = TapeTransportConfig(), now: Date = Date()) -> TapeTransportPanelModel {
    TapeTransportPanelModel(config: config, transport: transport, now: now)
}

// MARK: - Engine state -> view state

@Suite("TapeTransportPanelModel — engine state to view state")
@MainActor
struct TapeTransportPanelModelStateTests {

    @Test("An app whose tape was never armed shows its persisted config and nothing else")
    func neverArmed() {
        let built = model(nil, config: TapeTransportConfig(isEnabled: false, ringMinutes: 15))

        #expect(!built.isEnabled)
        #expect(built.ringMinutes == 15)
        #expect(built.capacitySeconds == 900)
        #expect(built.recordedSeconds == 0)
        #expect(built.isLive)
        #expect(built.exportState == .idle)
        #expect(built.loop == nil)
        #expect(!built.preservePitchAvailable, "keep-pitch is T7 and is not built")
    }

    @Test("An armed tape with no ring yet reports an empty tape sitting at live")
    func armedWithoutARing() {
        // No tap has attached, so there is no sample rate and nothing allocated.
        let transport = AppTapeTransport(
            identifier: "com.test.tape.ui",
            appName: "Test App",
            config: TapeTransportConfig(isEnabled: true, ringMinutes: 5),
            graceWait: {}
        )
        transport.setEnabled(true)

        let built = model(transport)
        #expect(built.isEnabled)
        #expect(built.capacitySeconds == 300)
        #expect(built.recordedSeconds == 0)
        #expect(built.isLive)
        #expect(built.displayState == .live)
    }

    @Test("Recorded time follows the write clock")
    func recordedTimeFollowsTheWriteClock() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)  // 24_064 frames = 30.08 s at 800 Hz

        let built = model(transport)
        #expect(abs(built.recordedSeconds - 30.08) < 0.01)
        #expect(built.isLive)
        #expect(built.timeSlotContent == .recordedTime("0:30"))
    }

    @Test("Recorded time stops at the reachable window, not at raw ring capacity")
    func recordedTimeStopsAtTheReachableWindow() async {
        let (transport, _) = await makeArmedTransport()
        // Past a full 1-minute ring: the oldest second is the writer's margin and
        // can never be played, so offering it on the scrub bar would be a lie.
        pump(transport, callbacks: 100)  // 51_200 frames > 48_000 capacity

        #expect(model(transport).recordedSeconds == 59)
    }

    @Test("A scrub puts the model behind live, with the LIVE button live")
    func scrubGoesBehindLive() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)

        transport.scrub(toSecondsBehindLive: 10)
        pump(transport, callbacks: 1)  // the RT thread consumes the command

        let built = model(transport)
        #expect(!built.isLive)
        #expect(abs(built.secondsBehindLive - 10) < 0.2)
        #expect(built.displayState == .behind)
        #expect(built.liveElementKind == .button)
        #expect(built.timeSlotContent == .behindTime("\u{2212}0:10"))
    }

    @Test("The brake reports stopped and offers play")
    func brakeReportsStopped() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)
        transport.scrub(toSecondsBehindLive: 10)
        pump(transport, callbacks: 1)

        transport.setBraked(true)

        let built = model(transport)
        #expect(built.isStopped)
        #expect(built.displayState == .stopped)
        #expect(built.chipContent == .stopped)
        #expect(built.primaryButton == .play)
    }

    @Test("Speed shows on the chip only once the tape is behind live")
    func speedChipOnlyShowsBehindLive() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)

        transport.setRate(0.5)
        #expect(model(transport).rate == 0.5)
        #expect(model(transport).chipContent == .hidden, "live passthrough ignores the rate")

        transport.scrub(toSecondsBehindLive: 10)
        pump(transport, callbacks: 1)
        #expect(model(transport).chipContent == .rate("0.5×"))
    }

    @Test("A loop is reported behind live, and drifts as live runs on")
    func loopDriftsWithLive() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)

        transport.grabLoop(lastSeconds: 10)
        let grabbed = try? #require(model(transport).loop)
        #expect(model(transport).isLooping)
        #expect(abs((grabbed?.endBehind ?? -1) - 0) < 0.01)
        #expect(abs((grabbed?.startBehind ?? -1) - 10) < 0.01)

        pump(transport, callbacks: 8)  // 4_096 frames = 5.12 s
        let drifted = try? #require(model(transport).loop)
        #expect(abs((drifted?.endBehind ?? -1) - 5.12) < 0.01)
        #expect(abs((drifted?.startBehind ?? -1) - 15.12) < 0.01)

        transport.clearLoop()
        #expect(model(transport).loop == nil)
    }

    @Test("A save shows progress, then a tick, then goes quiet")
    func exportStateProgression() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)
        let gate = ExportGate()
        transport.onExport = { _, _, _, _ in
            while !gate.isOpen { try? await Task.sleep(nanoseconds: 1_000_000) }
            return gate.result
        }

        #expect(transport.export(lastMinutes: 1))
        #expect(model(transport).exportState == .exporting)

        gate.isOpen = true
        await transport.waitForPendingWork()

        let finished = model(transport)
        guard case .done = finished.exportState else {
            Issue.record("expected the save to report done, got \(finished.exportState)")
            return
        }
        // The tick is a view-side timeout, not a latch.
        let later = model(transport, now: Date().addingTimeInterval(TapeTransportPanelModel.exportDoneDuration + 1))
        #expect(later.exportState == .idle)
    }

    @Test("A save that wrote no file never shows a tick")
    func failedExportShowsNoTick() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)
        let gate = ExportGate()
        gate.result = false
        gate.isOpen = true
        transport.onExport = { _, _, _, _ in gate.result }

        #expect(transport.export(lastMinutes: 1))
        await transport.waitForPendingWork()

        #expect(model(transport).exportState == .idle)
    }

    @Test("A device rate change raises the tape-restarted notice, which expires on its own")
    func clearedNoticeAppearsAndExpires() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)

        transport.rateChanged(to: 1_600)
        await transport.waitForPendingWork()

        let cleared = model(transport)
        #expect(cleared.clearedNoticeActive)
        #expect(cleared.displayState == .clearedNotice)
        #expect(cleared.timeSlotContent == .label(TapeTransportCopy.tapeRestartedLabel))
        #expect(cleared.recordedSeconds < 1, "the tape itself is gone")
        #expect(cleared.isLive)

        let later = model(transport, now: Date().addingTimeInterval(TapeTransportPanelModel.clearedNoticeDuration + 1))
        #expect(!later.clearedNoticeActive)
    }
}

// MARK: - Commands

@Suite("AppTapeTransport — the commands the strip sends")
@MainActor
struct AppTapeTransportCommandTests {

    @Test("A scrub released within the snap threshold returns to live instead of sitting just behind it")
    func scrubReleaseSnapsToLive() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)

        transport.scrub(toSecondsBehindLive: 0.2)
        transport.endScrub(snapToLiveWithin: TapeTransportMath.snapToLiveThreshold)
        pump(transport, callbacks: 4)

        #expect(model(transport).isLive)
    }

    @Test("A scrub released well behind live stays where it was dropped")
    func scrubReleaseOutsideThresholdStaysBehind() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)

        transport.scrub(toSecondsBehindLive: 5)
        transport.endScrub(snapToLiveWithin: TapeTransportMath.snapToLiveThreshold)
        pump(transport, callbacks: 1)

        let built = model(transport)
        #expect(!built.isLive)
        #expect(abs(built.secondsBehindLive - 5) < 0.2)
    }

    @Test("LIVE releases the brake — a stopped tape back at live is playing")
    func liveReleasesTheBrake() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)
        transport.scrub(toSecondsBehindLive: 10)
        pump(transport, callbacks: 1)
        transport.setBraked(true)

        transport.goLive()
        pump(transport, callbacks: 4)

        #expect(!transport.isBraked)
        #expect(!model(transport).isStopped)
    }

    @Test("Loop grab drops the read head at the loop start, so the button loops something audible")
    func loopGrabUnpins() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)

        transport.grabLoop(lastSeconds: 10)
        pump(transport, callbacks: 1)

        let built = model(transport)
        #expect(!built.isLive)
        #expect(abs(built.secondsBehindLive - 10) < 0.2)
    }

    @Test("Dragging a loop edge past its partner pushes the partner, never the dragged edge")
    func loopEdgeDragPushesTheOtherEdge() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)
        transport.grabLoop(lastSeconds: 10)

        // Drag the END edge (nearest live) back past the START edge.
        transport.setLoopEdge(isStart: false, secondsBehindLive: 10.5, minimumLength: TapeTransportMath.minimumLoopLength)

        let edges = try? #require(transport.loopSecondsBehindLive())
        #expect(abs((edges?.endBehind ?? -1) - 10.5) < 0.01, "the dragged edge lands where the finger is")
        #expect(abs((edges?.startBehind ?? -1) - 11.5) < 0.01, "its partner is pushed to keep the minimum length")
    }

    @Test("Disabling drops the loop and the brake, so the next ring cannot inherit them")
    func disableClearsTransientState() async {
        let (transport, _) = await makeArmedTransport()
        pump(transport, callbacks: 47)
        transport.grabLoop(lastSeconds: 10)
        transport.setBraked(true)

        transport.setEnabled(false)
        await transport.waitForPendingWork()

        #expect(transport.loopFrames == nil, "loop frames are on a write clock that is about to restart at zero")
        #expect(!transport.isBraked)
        #expect(transport.pendingScrubSecondsBehind == nil)
    }

    @Test("A ring rebuilt by a rate change inherits the speed the user set")
    func rebuiltRingInheritsTheRate() async {
        let (transport, _) = await makeArmedTransport()
        transport.setRate(2.0)

        transport.rateChanged(to: 1_600)
        await transport.waitForPendingWork()
        pump(transport, callbacks: 100)  // 51_200 frames = 32 s at 1600 Hz

        // Far enough behind that 2x cannot catch live inside the measurement and
        // trip the auto-pin, which would cap the advance and hide the rate.
        transport.scrub(toSecondsBehindLive: 20)
        pump(transport, callbacks: 1)  // consumes the seek and seeds the rate
        let ring = try? #require(transport.transport)
        let before = (ring?.diagnosticsSnapshot().readPositionQ ?? 0) >> 24

        pump(transport, callbacks: 10)  // 5_120 frames of wall clock
        let advanced = ((ring?.diagnosticsSnapshot().readPositionQ ?? 0) >> 24) - before

        // At 1.0x this would be ~5_120. Anything near 10_240 can only be the
        // requested 2.0x having reached the new ring.
        #expect(advanced > 9_000, "expected ~10_240 frames of tape per 5_120 frames of clock, got \(advanced)")
    }
}
