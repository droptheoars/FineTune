// FineTuneTests/TapeTransportRTTests.swift
// Offline harness for TapeTransportRT (Phase 2 spec §7, acceptance tests 1-7
// and 9). No live audio: a frame-indexed stereo ramp is written through
// writeAndRender exactly as the primary HAL callback would, and outputs are
// asserted EXACTLY (bit-equal Floats) wherever the spec demands exactness —
// rewind delay, fixed-point clock positions, horizon behaviour — and against
// the blend formula (small tolerance) inside jump crossfades.
//
// House convention: prove ordering, not timing. The horizon-collision test
// asserts against a recorded per-callback event log (clamp event precedes any
// effective-rate change; position deltas are exact), never wall-clock time.

import Foundation
import Testing
@testable import FineTune

// MARK: - Helpers

private let testSampleRate = 48000.0

/// Frame-indexed stereo ramp: L = n, R = n/2 — exact in Float32 below 2^24
/// frames, channel-distinct to catch channel swaps.
private func rampL(_ n: Int64) -> Float { Float(n) }
private func rampR(_ n: Int64) -> Float { Float(n) * 0.5 }

/// The exact fixed-point step the transport must derive for a rate (§2.3).
private func stepQ(_ rate: Float) -> Int64 {
    Int64((Double(rate) * 16_777_216.0).rounded())
}

/// Feeds the transport HAL-callback-sized buffers of the ramp, mirroring the
/// write clock in `nextFrame` so expected ring content is always `ramp(frame)`.
private final class Harness {
    let transport: TapeTransportRT
    var nextFrame: Int64 = 0

    init(capacityFrames: Int = 144_000, guardFrames: Int = 4096) {
        transport = TapeTransportRT(
            sampleRate: testSampleRate,
            capacityFrames: capacityFrames,
            horizonGuardFrames: guardFrames
        )
    }

    /// One primary-callback cycle with ramp input. Returns the render flag and
    /// the buffer contents after the call.
    @discardableResult
    func callback(_ frames: Int = 512) -> (rendered: Bool, out: [Float]) {
        var buffer = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            buffer[i * 2] = rampL(nextFrame + Int64(i))
            buffer[i * 2 + 1] = rampR(nextFrame + Int64(i))
        }
        nextFrame += Int64(frames)
        let rendered = buffer.withUnsafeMutableBufferPointer {
            transport.writeAndRender(interleavedStereo: $0.baseAddress!, frameCount: frames)
        }
        return (rendered, buffer)
    }

    func writeRamp(callbacks: Int, frames: Int = 512) {
        for _ in 0..<callbacks { _ = callback(frames) }
    }

    /// Muted-app path (E21): silence enters the tape, the ramp frames are lost.
    func silence(_ frames: Int) {
        transport.writeSilence(frameCount: frames)
        nextFrame += Int64(frames)
    }
}

/// nil when every frame in `frames` matches `expected` bit-exactly.
private func firstMismatch(
    _ out: [Float], frames: Range<Int>, _ expected: (Int) -> (Float, Float)
) -> String? {
    for i in frames {
        let (left, right) = expected(i)
        if out[i * 2] != left || out[i * 2 + 1] != right {
            return "frame \(i): got (\(out[i * 2]), \(out[i * 2 + 1])), expected (\(left), \(right))"
        }
    }
    return nil
}

// MARK: - Tests

@Suite("TapeTransportRT")
struct TapeTransportRTTests {

    @Test("Live passthrough is bit-exact, returns false, and advances the write clock once (§7.1)")
    func livePassthrough() {
        let harness = Harness()
        for _ in 0..<8 {
            let start = harness.nextFrame
            let (rendered, out) = harness.callback(512)
            #expect(rendered == false)
            let mismatch = firstMismatch(out, frames: 0..<512) { i in
                (rampL(start + Int64(i)), rampR(start + Int64(i)))
            }
            #expect(mismatch == nil)
        }
        let diagnostics = harness.transport.diagnosticsSnapshot()
        #expect(diagnostics.writeFrames == 4096)
        #expect(diagnostics.isPinnedToLive)
        #expect(diagnostics.lagFrames == 0)
    }

    @Test("Rewind at rate 1.0 reproduces the ramp delayed by exactly k frames (§7.2)")
    func rewindExactness() {
        let harness = Harness()
        harness.writeRamp(callbacks: 235)  // writeFrames = 120320
        let target = harness.transport.writtenFrames - 20_000
        harness.transport.requestSeek(toFrame: target)
        var produced = 0
        var checkedFrames = 0
        for _ in 0..<40 {
            let (rendered, out) = harness.callback(512)
            #expect(rendered)
            // The 20 ms unpin fade covers output frames [0, 960); everything
            // after must be the ramp delayed by exactly k — bit-equal.
            let firstExact = max(0, 960 - produced)
            if firstExact < 512 {
                let base = target + Int64(produced)
                let mismatch = firstMismatch(out, frames: firstExact..<512) { i in
                    (rampL(base + Int64(i)), rampR(base + Int64(i)))
                }
                #expect(mismatch == nil)
                checkedFrames += 512 - firstExact
            }
            produced += 512
        }
        #expect(checkedFrames > 18_000)
        // Fixed-point position asserted EQUAL, not approximate (§7.2).
        let diagnostics = harness.transport.diagnosticsSnapshot()
        #expect(diagnostics.readPositionQ == (target + Int64(produced)) << 24)
        #expect(diagnostics.seeksConsumed == 1)
    }

    @Test("Fixed-point clock: position after k callbacks equals target + k·N·step exactly (§7.3)")
    func clockExactness() {
        // (requested rate, effective rate after the ±4 clamp)
        let rates: [(Float, Float)] = [
            (0.25, 0.25), (0.5, 0.5), (0.7371, 0.7371), (1.0, 1.0),
            (1.5, 1.5), (2.0, 2.0), (3.999, 3.999),
            (-1.0, -1.0), (-2.0, -2.0),
            (10.0, 4.0), (-10.0, -4.0),
        ]
        for (requested, effective) in rates {
            let harness = Harness()
            harness.writeRamp(callbacks: 235)
            harness.transport.setTargetRate(requested)
            harness.transport.requestSeek(toFrame: 80_000)
            var frames = 0
            for _ in 0..<20 {
                harness.callback(512)
                frames += 512
            }
            let expected = (Int64(80_000) << 24) + Int64(frames) * stepQ(effective)
            #expect(
                harness.transport.diagnosticsSnapshot().readPositionQ == expected,
                "rate \(requested)"
            )
        }
        // r = 1.0 advance is integer by construction.
        #expect(stepQ(1.0) == 1 << 24)
    }

    @Test("Reads spanning the physical wrap seam are exact (E31, §7.3)")
    func wrapSeam() {
        let harness = Harness(capacityFrames: 96_000)
        harness.writeRamp(callbacks: 227)  // writeFrames = 116224 — ring wrapped
        let target: Int64 = 95_000         // ring index 95000, 1000 frames before the seam
        harness.transport.requestSeek(toFrame: target)
        var out: [Float] = []
        for _ in 0..<4 { out += harness.callback(512).out }
        // Frames 960..<2048 cross absolute frame 96000 = ring index 0.
        let mismatch = firstMismatch(out, frames: 960..<2048) { i in
            (rampL(target + Int64(i)), rampR(target + Int64(i)))
        }
        #expect(mismatch == nil)
    }

    @Test("Horizon collision: clamp event precedes the effective-rate change, no jump-cuts, requested rate restored (E18, §7.4)")
    func horizonCollision() {
        let harness = Harness()
        harness.writeRamp(callbacks: 293)  // writeFrames = 150016
        harness.transport.setTargetRate(0.25)
        let written = harness.transport.writtenFrames
        let trailing = written - 144_000 + 48_000
        harness.transport.requestSeek(toFrame: trailing + 4096 + 1888)

        struct LogEntry {
            let atHorizon: Bool
            let clampCount: Int64
            let positionQ: Int64
        }
        var log: [LogEntry] = []
        var outputs: [[Float]] = []
        for _ in 0..<30 {
            let (_, out) = harness.callback(512)
            let diagnostics = harness.transport.diagnosticsSnapshot()
            log.append(LogEntry(
                atHorizon: diagnostics.isAtHorizon,
                clampCount: diagnostics.clampEventCount,
                positionQ: diagnostics.readPositionQ
            ))
            outputs.append(out)
        }

        let slowDelta = Int64(512) * stepQ(0.25)
        let liveDelta = Int64(512) << 24
        let firstHorizon = log.firstIndex { $0.atHorizon }
        #expect(firstHorizon != nil)
        guard let firstHorizon else { return }
        // Ordering: the clamp event is recorded AT the first forced callback,
        // never before, and the effective-rate change never precedes it.
        #expect(firstHorizon > 0)
        #expect(log[firstHorizon].clampCount == 1)
        #expect(log[firstHorizon - 1].clampCount == 0)
        for k in 1..<log.count {
            let delta = log[k].positionQ - log[k - 1].positionQ
            if k < firstHorizon {
                #expect(delta == slowDelta, "callback \(k)")
            } else {
                #expect(delta == liveDelta, "callback \(k)")
            }
        }
        // No §D jump-cut signature: consecutive output samples step by the
        // effective rate (0.25 or 1.0) — a window-clamp skip would step by
        // hundreds of frames. Fade frames (first 960) excluded.
        var maxStep: Float = 0
        var previous: Float? = nil
        for (callbackIndex, out) in outputs.enumerated() {
            for i in 0..<512 {
                let j = callbackIndex * 512 + i
                if j < 960 {
                    previous = nil
                    continue
                }
                if let previousValue = previous {
                    maxStep = max(maxStep, abs(out[i * 2] - previousValue))
                }
                previous = out[i * 2]
            }
        }
        #expect(maxStep < 1.5, "max frame-to-frame output step \(maxStep)")

        // Releasing the pressure restores the REQUESTED rate — target was
        // never overwritten.
        harness.transport.requestSeek(toFrame: harness.transport.writtenFrames - 20_000)
        harness.writeRamp(callbacks: 3)  // consume + finish the 960-frame fade
        let beforeQ = harness.transport.diagnosticsSnapshot().readPositionQ
        harness.callback(512)
        let afterQ = harness.transport.diagnosticsSnapshot().readPositionQ
        #expect(afterQ - beforeQ == slowDelta)
        #expect(!harness.transport.diagnosticsSnapshot().isAtHorizon)
    }

    @Test("Seek jump is an equal-power blend over exactly 20 ms (§7.5)")
    func seekBlend() {
        let harness = Harness()
        harness.writeRamp(callbacks: 235)
        let target = harness.transport.writtenFrames - 30_000
        harness.transport.requestSeek(toFrame: target)
        var produced = 0
        var maxRelativeError: Float = 0
        var exactMismatch: String? = nil
        for _ in 0..<3 {
            let liveStart = harness.nextFrame
            let (rendered, out) = harness.callback(512)
            #expect(rendered)
            for i in 0..<512 {
                let j = produced + i
                let ringL = rampL(target + Int64(j))
                let ringR = rampR(target + Int64(j))
                if j < 960 {
                    // Unpinning fades OUT of the live buffer, INTO the ring head.
                    let theta = (Float(j + 1) / Float(960)) * (Float.pi / 2)
                    let expectedL = cosf(theta) * rampL(liveStart + Int64(i)) + sinf(theta) * ringL
                    let expectedR = cosf(theta) * rampR(liveStart + Int64(i)) + sinf(theta) * ringR
                    maxRelativeError = max(
                        maxRelativeError,
                        abs(out[i * 2] - expectedL) / max(abs(expectedL), 1),
                        abs(out[i * 2 + 1] - expectedR) / max(abs(expectedR), 1)
                    )
                } else if exactMismatch == nil, out[i * 2] != ringL || out[i * 2 + 1] != ringR {
                    // Duration is exact: from frame 960 the output is the pure
                    // ring side, bit-equal (catches a too-long fade; the blend
                    // check above catches a too-short one).
                    exactMismatch = "frame \(j)"
                }
            }
            produced += 512
        }
        #expect(maxRelativeError < 1e-5)
        #expect(exactMismatch == nil)
    }

    @Test("LIVE return blends over exactly 50 ms then pins with a bit-exact hand-off (§7.5)")
    func liveReturn() {
        let harness = Harness()
        harness.writeRamp(callbacks: 235)
        harness.transport.requestSeek(toFrame: harness.transport.writtenFrames - 30_000)
        harness.writeRamp(callbacks: 4)  // unpin fade fully done
        let shadowBase = harness.transport.diagnosticsSnapshot().readPositionQ >> 24
        harness.transport.requestLive()

        var produced = 0
        var renderedCallbacks = 0
        var sawPinned = false
        var maxRelativeError: Float = 0
        var tailMismatch: String? = nil
        for _ in 0..<8 {
            let liveStart = harness.nextFrame
            let (rendered, out) = harness.callback(512)
            if !rendered {
                sawPinned = true
                let mismatch = firstMismatch(out, frames: 0..<512) { i in
                    (rampL(liveStart + Int64(i)), rampR(liveStart + Int64(i)))
                }
                #expect(mismatch == nil)
                break
            }
            renderedCallbacks += 1
            for i in 0..<512 {
                let j = produced + i
                let liveL = rampL(liveStart + Int64(i))
                if j < 2400 {
                    let theta = (Float(j + 1) / Float(2400)) * (Float.pi / 2)
                    let expectedL = cosf(theta) * rampL(shadowBase + Int64(j)) + sinf(theta) * liveL
                    maxRelativeError = max(
                        maxRelativeError, abs(out[i * 2] - expectedL) / max(abs(expectedL), 1)
                    )
                } else if tailMismatch == nil, out[i * 2] != liveL {
                    // After the fade completes mid-callback the rest of the
                    // buffer is untouched live audio.
                    tailMismatch = "frame \(j)"
                }
            }
            produced += 512
        }
        #expect(maxRelativeError < 1e-5)
        #expect(tailMismatch == nil)
        #expect(renderedCallbacks == 5)  // 2400-frame fade pins inside callback 5
        #expect(sawPinned)
        #expect(harness.transport.diagnosticsSnapshot().isPinnedToLive)
    }

    @Test("Loop wraps at the boundary through a 10 ms blend with exact period (§7.5)")
    func loopWrap() {
        let harness = Harness()
        harness.writeRamp(callbacks: 118)  // writeFrames = 60416, trailing edge 0
        harness.transport.setLoop(startFrame: 30_000, endFrame: 34_800)
        harness.transport.requestSeek(toFrame: 30_000)
        var out: [Float] = []
        for _ in 0..<24 { out += harness.callback(512).out }  // 12288 frames ≈ 2.5 laps

        // Pure frames are exact: position is 30000 + (j mod 4800), skipping
        // the 960-frame entry fade and each 480-frame wrap blend.
        var mismatch: String? = nil
        for j in 960..<12_288 {
            let phase = j % 4_800
            if j >= 4_800 && phase < 480 { continue }
            let expected = 30_000 + Int64(phase)
            if out[j * 2] != rampL(expected) || out[j * 2 + 1] != rampR(expected) {
                mismatch = "frame \(j)"
                break
            }
        }
        #expect(mismatch == nil)

        // The wrap blend matches the equal-power formula: shadow continues
        // past the loop end while the head restarts at the loop start.
        for b in [0, 100, 250, 400] {
            let j = 4_800 + b
            let theta = (Float(b + 1) / Float(480)) * (Float.pi / 2)
            let expected = cosf(theta) * rampL(34_800 + Int64(b)) + sinf(theta) * rampL(30_000 + Int64(b))
            #expect(abs(out[j * 2] - expected) <= max(abs(expected) * 1e-5, 1e-3), "blend frame \(j)")
        }

        // A loop squeezed below twice the blend degrades honestly (§2.5).
        harness.transport.setLoop(startFrame: 40_000, endFrame: 40_100)
        harness.callback(512)
        #expect(harness.transport.diagnosticsSnapshot().isLoopDegraded)
    }

    @Test("Fast-forward into the live edge auto-pins through the live blend (Q2)")
    func autoLiveOnFastForward() {
        let harness = Harness()
        harness.writeRamp(callbacks: 235)
        harness.transport.setTargetRate(2.0)
        harness.transport.requestSeek(toFrame: harness.transport.writtenFrames - 6_000)
        var pinned = false
        for _ in 0..<40 {
            if !harness.callback(512).rendered {
                pinned = true
                break
            }
        }
        #expect(pinned)
        #expect(harness.transport.diagnosticsSnapshot().isPinnedToLive)
    }

    @Test("Mirrored buffers: write clock and read head advance once, copyLastOutput matches (E16, §7.6)")
    func mirrorOncePerCallback() {
        let harness = Harness()
        harness.writeRamp(callbacks: 235)
        harness.transport.requestSeek(toFrame: 100_000)
        harness.writeRamp(callbacks: 3)  // fade fully done
        let writeBefore = harness.transport.writtenFrames
        let positionBefore = harness.transport.diagnosticsSnapshot().readPositionQ

        let (rendered, out) = harness.callback(512)
        #expect(rendered)
        // Ring gained N frames (not 2N) and the head advanced once.
        #expect(harness.transport.writtenFrames == writeBefore + 512)
        #expect(harness.transport.diagnosticsSnapshot().readPositionQ == positionBefore + (Int64(512) << 24))

        // Second mirrored buffer equals the first, bit-exact.
        var mirror = [Float](repeating: -1, count: 512 * 2)
        mirror.withUnsafeMutableBufferPointer {
            harness.transport.copyLastOutput(into: $0.baseAddress!, frameCount: 512)
        }
        #expect(mirror == out)

        // Excess frames zero-fill (last-resort fallback, same as the chain).
        var oversized = [Float](repeating: -1, count: 600 * 2)
        oversized.withUnsafeMutableBufferPointer {
            harness.transport.copyLastOutput(into: $0.baseAddress!, frameCount: 600)
        }
        #expect(Array(oversized[0..<1024]) == out)
        #expect(oversized[1024...].allSatisfy { $0 == 0 })
    }

    @Test("writeSilence keeps the timeline continuous; rewind across a muted span plays exact-length silence (E21, §7.7)")
    func muteTimeline() {
        let harness = Harness()
        harness.writeRamp(callbacks: 2)  // frames 0..<1024: ramp
        harness.silence(512)             // frames 1024..<1536: silence
        #expect(harness.transport.writtenFrames == 1536)
        harness.writeRamp(callbacks: 2)  // frames 1536..<2560: ramp
        harness.transport.requestSeek(toFrame: 0)
        var out: [Float] = []
        for _ in 0..<5 { out += harness.callback(512).out }
        let mismatch = firstMismatch(out, frames: 960..<2_560) { i in
            let n = Int64(i)
            if n >= 1024 && n < 1536 { return (0, 0) }
            return (rampL(n), rampR(n))
        }
        #expect(mismatch == nil)
    }

    @Test("Rate changes ramp through the one-pole smoother and converge to the exact step")
    func rateRamp() {
        let harness = Harness()
        harness.writeRamp(callbacks: 235)
        harness.transport.requestSeek(toFrame: 80_000)
        harness.writeRamp(callbacks: 3)  // fade done, cruising at 1.0
        harness.transport.setTargetRate(0.5)
        var deltas: [Int64] = []
        var lastQ = harness.transport.diagnosticsSnapshot().readPositionQ
        for _ in 0..<60 {
            harness.callback(512)
            let positionQ = harness.transport.diagnosticsSnapshot().readPositionQ
            deltas.append(positionQ - lastQ)
            lastQ = positionQ
        }
        let targetDelta = Int64(512) * stepQ(0.5)
        let fullDelta = Int64(512) << 24
        #expect(deltas.last == targetDelta)  // snapped: stepping exact again
        for (earlier, later) in zip(deltas, deltas.dropFirst()) {
            #expect(later <= earlier)  // monotone ramp, no overshoot
            #expect(later >= targetDelta && earlier < fullDelta)
        }
    }

    @Test("Memory: ring allocation is exactly capacity × 2 × 4 bytes; instances deallocate cleanly (§7.9)")
    func memoryBounded() {
        let transport = TapeTransportRT(sampleRate: testSampleRate, capacityFrames: 144_000)
        #expect(transport.allocatedRingBytes == 144_000 * 2 * 4)
        #expect(TapeTransportRT.mirrorCapacityFrames == 16_384)  // fixed O(1) state
        for _ in 0..<5 {
            var strong: TapeTransportRT? = TapeTransportRT(
                sampleRate: testSampleRate, capacityFrames: 96_000
            )
            weak var leaked = strong
            var buffer = [Float](repeating: 0.25, count: 512 * 2)
            for _ in 0..<4 {
                buffer.withUnsafeMutableBufferPointer {
                    _ = strong?.writeAndRender(interleavedStereo: $0.baseAddress!, frameCount: 512)
                }
            }
            strong?.requestSeek(toFrame: 0)
            buffer.withUnsafeMutableBufferPointer {
                _ = strong?.writeAndRender(interleavedStereo: $0.baseAddress!, frameCount: 512)
            }
            strong = nil
            #expect(leaked == nil)
        }
    }
}
