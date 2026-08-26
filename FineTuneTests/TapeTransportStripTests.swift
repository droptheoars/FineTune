// FineTuneTests/TapeTransportStripTests.swift
// T8: pure logic behind the tape transport strip — time formatting, the
// scrub position <-> time mapping in both directions, the state -> label
// mapping from the spec's §5 table, and the small pieces of gesture math
// (loop-edge clamping, speed-slider mapping) that back a real branch.
// No views instantiated.

import Testing
@testable import FineTune

@Suite("TapeTransportMath — time formatting")
struct TapeTransportTimeFormattingTests {
    @Test(
        "formatTime renders m:ss, zero-padded, never hours",
        arguments: [
            (0.0, "0:00"),
            (5.0, "0:05"),
            (65.0, "1:05"),
            (599.0, "9:59"),
            (900.0, "15:00"), // full 15-minute ring, still m:ss
            (61.6, "1:02")    // rounds to nearest second
        ]
    )
    func formatTime(seconds: Double, expected: String) {
        #expect(TapeTransportMath.formatTime(seconds) == expected)
    }

    @Test("formatBehind prefixes the minus sign (U+2212), not a hyphen")
    func formatBehindUsesMinusSign() {
        let text = TapeTransportMath.formatBehind(134)
        #expect(text == "\u{2212}2:14")
        #expect(!text.hasPrefix("-")) // ASCII hyphen would be wrong
    }

    @Test(
        "formatRate trims trailing zeros, keeps at most 2 decimals",
        arguments: [
            (0.5, "0.5×"),
            (0.75, "0.75×"),
            (1.5, "1.5×"),
            (2.0, "2×")
        ]
    )
    func formatRate(rate: Double, expected: String) {
        #expect(TapeTransportMath.formatRate(rate) == expected)
    }

    @Test("formatSpeedReadout always keeps one decimal, even at 1.0x")
    func formatSpeedReadoutKeepsDecimal() {
        #expect(TapeTransportMath.formatSpeedReadout(1.0) == "1.0×")
        #expect(TapeTransportMath.formatSpeedReadout(0.5) == "0.5×")
    }
}

@Suite("TapeTransportMath — scrub position <-> time mapping")
struct TapeTransportScrubMappingTests {
    @Test("trackFraction(forSecondsBehindLive:) puts live at fraction 1")
    func liveEdgeMapsToFractionOne() {
        #expect(TapeTransportMath.trackFraction(forSecondsBehindLive: 0, capacitySeconds: 300) == 1)
    }

    @Test("trackFraction(forSecondsBehindLive:) puts the oldest capacity point at fraction 0")
    func oldestCapacityMapsToFractionZero() {
        #expect(TapeTransportMath.trackFraction(forSecondsBehindLive: 300, capacitySeconds: 300) == 0)
    }

    @Test("trackFraction is the midpoint at half the ring's capacity")
    func midCapacityMapsToMidpoint() {
        #expect(TapeTransportMath.trackFraction(forSecondsBehindLive: 150, capacitySeconds: 300) == 0.5)
    }

    @Test("secondsBehindLive(forTrackFraction:) is the exact inverse of trackFraction, within the recorded region")
    func roundTripsWithinRecordedRegion() {
        let capacity = 300.0
        let recorded = 300.0
        for behind in stride(from: 0.0, through: capacity, by: 30) {
            let fraction = TapeTransportMath.trackFraction(forSecondsBehindLive: behind, capacitySeconds: capacity)
            let roundTripped = TapeTransportMath.secondsBehindLive(forTrackFraction: fraction, capacitySeconds: capacity, recordedSeconds: recorded)
            #expect(abs(roundTripped - behind) < 0.001)
        }
    }

    @Test("Dragging to the live terminus (fraction 1) always yields 0 seconds behind")
    func liveTerminusYieldsZeroBehind() {
        let seconds = TapeTransportMath.secondsBehindLive(forTrackFraction: 1, capacitySeconds: 300, recordedSeconds: 120)
        #expect(seconds == 0)
    }

    @Test("Dragging past the oldest recorded audio clamps to the oldest recorded edge, not ring capacity")
    func dragPastOldestRecordedClampsToRecordedEdge() {
        // Ring can hold 300s but only 120s has actually been recorded — the
        // rest of the track (fraction 0...0.6) is capacity with no audio.
        let seconds = TapeTransportMath.secondsBehindLive(forTrackFraction: 0, capacitySeconds: 300, recordedSeconds: 120)
        #expect(seconds == 120)
    }

    @Test("A fully-recorded ring lets the drag reach the true oldest point")
    func fullyRecordedRingReachesCapacityEdge() {
        let seconds = TapeTransportMath.secondsBehindLive(forTrackFraction: 0, capacitySeconds: 300, recordedSeconds: 300)
        #expect(seconds == 300)
    }

    @Test("Out-of-range fractions clamp rather than extrapolate")
    func outOfRangeFractionsClamp() {
        #expect(TapeTransportMath.secondsBehindLive(forTrackFraction: -0.5, capacitySeconds: 300, recordedSeconds: 300) == 300)
        #expect(TapeTransportMath.secondsBehindLive(forTrackFraction: 1.5, capacitySeconds: 300, recordedSeconds: 300) == 0)
    }
}

@Suite("TapeTransportPanelModel — state -> label/affordance mapping (§5)")
struct TapeTransportStateTableTests {
    @Test("Row 2: live shows recorded time, hides the chip, and the LIVE element is an inert label")
    func liveRow() {
        let model = TapeTransportPanelModel(isEnabled: true, recordedSeconds: 277, secondsBehindLive: 0, isLive: true)
        #expect(model.displayState == .live)
        #expect(model.timeSlotContent == .recordedTime("4:37"))
        #expect(model.chipContent == .hidden)
        #expect(model.liveElementKind == .inertLabel)
        #expect(model.primaryButton == .stop)
    }

    @Test("Row 3: behind at 1.0x shows the amber offset, hides the chip, LIVE becomes a button")
    func behindRateOneRow() {
        let model = TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 134, isLive: false, rate: 1.0)
        #expect(model.displayState == .behind)
        #expect(model.timeSlotContent == .behindTime("\u{2212}2:14"))
        #expect(model.chipContent == .hidden)
        #expect(model.liveElementKind == .button)
    }

    @Test("Row 4: behind at a non-1.0x rate shows the rate chip")
    func behindWithRateChipRow() {
        let model = TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 161, isLive: false, rate: 0.5)
        #expect(model.displayState == .behind)
        #expect(model.chipContent == .rate("0.5×"))
    }

    @Test("Row 5: stopped shows the amber Stopped chip, overriding any rate chip, and offers play instead of stop")
    func stoppedRow() {
        let model = TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 182, isLive: false, rate: 0.5, isStopped: true)
        #expect(model.displayState == .stopped)
        #expect(model.chipContent == .stopped)
        #expect(model.liveElementKind == .button)
        #expect(model.primaryButton == .play)
    }

    @Test("Row 6: an active loop is reported by isLooping regardless of the underlying live/behind state")
    func loopingRow() {
        let model = TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 65, isLive: false, loop: (startBehind: 75, endBehind: 59))
        #expect(model.isLooping)
    }

    @Test("Row 7: at horizon, the time slot becomes the End of tape label and the chip hides")
    func atHorizonRow() {
        let model = TapeTransportPanelModel(isEnabled: true, recordedSeconds: 300, secondsBehindLive: 300, isLive: false, rate: 0.5, atHorizon: true)
        #expect(model.displayState == .atHorizon)
        #expect(model.timeSlotContent == .label("End of tape"))
        #expect(model.labelStyle == .behind)
        #expect(model.chipContent == .hidden)
        #expect(model.liveElementKind == .button)
    }

    @Test("Row 8: the cleared-tape notice becomes the Tape restarted label, and LIVE stays an inert label")
    func clearedNoticeRow() {
        let model = TapeTransportPanelModel(isEnabled: true, recordedSeconds: 3, secondsBehindLive: 0, isLive: true, clearedNoticeActive: true)
        #expect(model.displayState == .clearedNotice)
        #expect(model.timeSlotContent == .label("Tape restarted"))
        #expect(model.labelStyle == .info)
        #expect(model.liveElementKind == .inertLabel)
    }

    @Test("At horizon outranks a simultaneous cleared-notice flag — the table has no row where both show")
    func horizonOutranksClearedNotice() {
        let model = TapeTransportPanelModel(isEnabled: true, atHorizon: true, clearedNoticeActive: true)
        #expect(model.displayState == .atHorizon)
    }
}

@Suite("TapeTransportMath — loop edge clamping and speed mapping")
struct TapeTransportGestureMathTests {
    @Test("Loop edges cannot cross: dragging the start edge past the end edge stops at the minimum loop length")
    func startEdgeCannotCrossEnd() {
        let clamped = TapeTransportMath.clampedLoopEdges(start: 10, end: 20, draggedEdge: .start, recordedSeconds: 300)
        #expect(clamped.startBehind == 21) // pushed to end + minimumLoopLength, not left at 10
    }

    @Test("Loop edges cannot cross: dragging the end edge past the start edge stops at the minimum loop length")
    func endEdgeCannotCrossStart() {
        let clamped = TapeTransportMath.clampedLoopEdges(start: 20, end: 30, draggedEdge: .end, recordedSeconds: 300)
        #expect(clamped.endBehind == 19)
    }

    @Test("Loop edges clamp to the recorded region")
    func loopEdgesClampToRecordedRegion() {
        let clamped = TapeTransportMath.clampedLoopEdges(start: 500, end: -20, draggedEdge: .start, recordedSeconds: 300)
        #expect(clamped.startBehind == 300)
        #expect(clamped.endBehind == 0)
    }

    @Test("The speed slider's midpoint (fraction 0.5) is always 1.0x")
    func sliderMidpointIsUnityRate() {
        #expect(abs(TapeTransportMath.rate(forSliderFraction: 0.5) - 1.0) < 0.0001)
        #expect(abs(TapeTransportMath.sliderFraction(forRate: 1.0) - 0.5) < 0.0001)
    }

    @Test("Speed slider mapping round-trips across its full range")
    func speedSliderRoundTrips() {
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            let rate = TapeTransportMath.rate(forSliderFraction: fraction)
            let roundTripped = TapeTransportMath.sliderFraction(forRate: rate)
            #expect(abs(roundTripped - fraction) < 0.001)
        }
    }

    @Test("A rate within 0.05 of 1.0x snaps to exactly 1.0x; further away it does not")
    func speedSnapsNearUnity() {
        #expect(TapeTransportMath.snappedRate(1.04) == 1.0)
        #expect(TapeTransportMath.snappedRate(0.96) == 1.0)
        #expect(TapeTransportMath.snappedRate(1.10) == 1.10)
    }

    @Test("Speed slider mapping round-trips at both ends of its range and exactly at 1.0x")
    func speedSliderRoundTripsAtBoundaries() {
        for rate in [0.25, 1.0, 2.0] {
            let fraction = TapeTransportMath.sliderFraction(forRate: rate)
            let roundTripped = TapeTransportMath.rate(forSliderFraction: fraction)
            #expect(abs(roundTripped - rate) < 0.0001)
        }
        #expect(TapeTransportMath.sliderFraction(forRate: 0.25) == 0)
        #expect(TapeTransportMath.sliderFraction(forRate: 2.0) == 1)
    }

    @Test("rate(forSliderFraction:) alone never applies the detent; only snappedRate does, which is what lets the Tape panel's slider report every intermediate drag value un-snapped and apply the detent once, on release")
    func rateFromFractionIsNotAutoSnapped() {
        let nearUnityFraction = TapeTransportMath.sliderFraction(forRate: 1.04)
        let raw = TapeTransportMath.rate(forSliderFraction: nearUnityFraction)
        #expect(abs(raw - 1.04) < 0.0001)
        #expect(raw != 1.0)
        #expect(TapeTransportMath.snappedRate(raw) == 1.0)
    }
}
