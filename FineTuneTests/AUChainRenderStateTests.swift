// FineTuneTests/AUChainRenderStateTests.swift
// Offline render harness for AUChainRenderState (spec §8 T2 gate).
//
// Renders through REAL Apple Audio Units (AUDelay, AUNewTimePitch) plus
// hand-written stub render blocks, covering: bit-exact dry passthrough on an
// empty chain, real-AU processing, TimePitch steady state at rate 1.0,
// latency summing, underflow/underconsumption counters, NaN scrub, slice
// processing of oversized callbacks, and the E1 mirror primitive.

import Accelerate
import AudioToolbox
import AVFAudio
import Testing
@testable import FineTune

// MARK: - Helpers

private let testSampleRate = 48000.0

/// Instantiate, configure, and allocate a real Apple AU the way AppAUChain
/// will (deinterleaved stereo Float32, maxFrames 4096, input bus enabled —
/// without isEnabled the v2 bridge fails renders with kAudioUnitErr_NoConnection).
private func makeAppleAU(type: OSType, subtype: OSType) throws -> AUAudioUnit {
    let desc = AudioComponentDescription(
        componentType: type,
        componentSubType: subtype,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    let au = try AUAudioUnit(componentDescription: desc)
    au.maximumFramesToRender = 4096
    let format = AVAudioFormat(standardFormatWithSampleRate: testSampleRate, channels: 2)!
    try au.inputBusses[0].setFormat(format)
    try au.outputBusses[0].setFormat(format)
    au.inputBusses[0].isEnabled = true
    try au.allocateRenderResources()
    return au
}

/// Interleaved stereo 440 Hz sine, phase-continuous via startFrame.
private func makeSine(frames: Int, startFrame: Int = 0, amplitude: Float = 0.5) -> [Float] {
    let omega = 2.0 * Double.pi * 440.0 / testSampleRate
    var buffer = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let sample = amplitude * Float(sin(omega * Double(startFrame + i)))
        buffer[i * 2] = sample
        buffer[i * 2 + 1] = sample
    }
    return buffer
}

private func render(_ state: AUChainRenderState, _ buffer: inout [Float]) -> Bool {
    let frames = buffer.count / 2
    return buffer.withUnsafeMutableBufferPointer {
        state.render(interleavedStereo: $0.baseAddress!, frameCount: frames)
    }
}

// MARK: - Stub render blocks

/// Well-behaved node: pulls exactly frameCount, scales in place.
private func gainStub(_ gain: Float) -> AUChainRawRenderBlock {
    return { _, tsPtr, frameCount, _, outputData, pull in
        guard let pull else { return kAudioUnitErr_NoConnection }
        var pullFlags = AudioUnitRenderActionFlags()
        let status = withUnsafeMutablePointer(to: &pullFlags) {
            pull($0, tsPtr, frameCount, 0, outputData)
        }
        guard status == noErr else { return status }
        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        for b in 0..<abl.count {
            guard let data = abl[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(frameCount) { data[i] *= gain }
        }
        return noErr
    }
}

/// Over-puller: pulls frameCount, then pulls 64 more (past the provided frames).
private let overPullStub: AUChainRawRenderBlock = { _, tsPtr, frameCount, _, outputData, pull in
    guard let pull else { return kAudioUnitErr_NoConnection }
    var pullFlags = AudioUnitRenderActionFlags()
    _ = withUnsafeMutablePointer(to: &pullFlags) { pull($0, tsPtr, frameCount, 0, outputData) }
    _ = withUnsafeMutablePointer(to: &pullFlags) { pull($0, tsPtr, 64, 0, outputData) }
    return noErr
}

/// Short-server: consumes only half of what the cycle provides.
private let shortServeStub: AUChainRawRenderBlock = { _, tsPtr, frameCount, _, outputData, pull in
    guard let pull else { return kAudioUnitErr_NoConnection }
    var pullFlags = AudioUnitRenderActionFlags()
    _ = withUnsafeMutablePointer(to: &pullFlags) { pull($0, tsPtr, frameCount / 2, 0, outputData) }
    return noErr
}

private final class NaNToggle: @unchecked Sendable {
    var emitNaN = true
}

/// Pulls cleanly, then poisons sample 0 of channel 0 while the toggle is on.
private func nanStub(_ toggle: NaNToggle) -> AUChainRawRenderBlock {
    return { _, tsPtr, frameCount, _, outputData, pull in
        guard let pull else { return kAudioUnitErr_NoConnection }
        var pullFlags = AudioUnitRenderActionFlags()
        let status = withUnsafeMutablePointer(to: &pullFlags) {
            pull($0, tsPtr, frameCount, 0, outputData)
        }
        guard status == noErr else { return status }
        if toggle.emitNaN {
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            if let data = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                data[0] = .nan
            }
        }
        return noErr
    }
}

// MARK: - Tests

@Suite("AUChainRenderState")
struct AUChainRenderStateTests {

    // Gate case: empty chain — bit-exact dry passthrough.
    @Test func emptyChainIsBitExactDryPassthrough() {
        let state = AUChainRenderState(nodes: [], sampleRate: testSampleRate)
        var buffer = makeSine(frames: 512)
        let reference = buffer

        let rendered = render(state, &buffer)

        #expect(rendered == false)
        #expect(buffer == reference)
        #expect(state.totalLatencySamples == 0)
        #expect(state.nodeCount == 0)
    }

    // Gate case: real AUDelay renders and measurably changes the signal.
    @Test func realAUDelayRendersAndChangesSignal() throws {
        let au = try makeAppleAU(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_Delay)
        let latencySamples = Int((au.latency * testSampleRate).rounded())
        let state = AUChainRenderState(
            nodes: [.init(audioUnit: au, latencySamples: latencySamples)],
            sampleRate: testSampleRate
        )

        var maxDiff: Float = 0
        for block in 0..<8 {
            var buffer = makeSine(frames: 512, startFrame: block * 512)
            let dry = buffer
            let rendered = render(state, &buffer)
            #expect(rendered == true)
            for i in 0..<buffer.count {
                #expect(buffer[i].isFinite)
                #expect(abs(buffer[i]) <= 4.0)
                maxDiff = max(maxDiff, abs(buffer[i] - dry[i]))
            }
        }
        // AUDelay's default 50% wet/dry mix must visibly alter the signal.
        #expect(maxDiff > 0.05)

        let diag = state.diagnosticsSnapshot()
        #expect(diag.count == 1)
        #expect(diag[0].nanStrikes == 0)

        withExtendedLifetime(au) {}
    }

    // Gate case (pinned acceptance path): AUNewTimePitch at rate 1.0 renders
    // cleanly in steady state — signal comes through, no rate mismatch counted.
    @Test func auNewTimePitchAtUnityRateRendersCleanly() throws {
        let au = try makeAppleAU(
            type: kAudioUnitType_FormatConverter,
            subtype: kAudioUnitSubType_NewTimePitch
        )
        let latencySamples = Int((au.latency * testSampleRate).rounded())
        let state = AUChainRenderState(
            nodes: [.init(audioUnit: au, latencySamples: latencySamples)],
            sampleRate: testSampleRate
        )
        #expect(state.totalLatencySamples == latencySamples)

        let blocks = 40
        let frames = 512
        var lastQuarterRMS: Float = 0
        for block in 0..<blocks {
            var buffer = makeSine(frames: frames, startFrame: block * frames)
            let rendered = render(state, &buffer)
            #expect(rendered == true)
            for sample in buffer {
                #expect(sample.isFinite)
                #expect(abs(sample) <= 4.0)
            }
            if block >= blocks * 3 / 4 {
                var sumSquares: Float = 0
                for i in 0..<frames { sumSquares += buffer[i * 2] * buffer[i * 2] }
                lastQuarterRMS = max(lastQuarterRMS, sqrtf(sumSquares / Float(frames)))
            }
        }
        // Steady state: 0.5-amplitude sine → RMS ≈ 0.35. Must not be silent.
        #expect(lastQuarterRMS > 0.2)
        #expect(lastQuarterRMS < 0.6)

        // At rate 1.0 the unit pulls exactly N per cycle from the first cycle
        // (verified by probing) — no mismatch may be counted.
        let diag = state.diagnosticsSnapshot()[0]
        #expect(diag.underflowCount == 0)
        #expect(diag.underconsumptionCount == 0)
        #expect(diag.consecutiveMismatchCycles == 0)
        #expect(diag.nanStrikes == 0)

        withExtendedLifetime(au) {}
    }

    // Gate case: reported total latency is the sum of node latencies.
    @Test func totalLatencyIsSumOfNodeLatencies() {
        let state = AUChainRenderState(
            nodes: [
                .init(rawRenderBlock: gainStub(1.0), latencySamples: 100),
                .init(rawRenderBlock: gainStub(1.0), latencySamples: 250),
            ],
            sampleRate: testSampleRate
        )
        #expect(state.totalLatencySamples == 350)
        let diag = state.diagnosticsSnapshot()
        #expect(diag.map(\.latencySamples) == [100, 250])
    }

    // Gate case: a pull past the provided frames bumps the underflow counter.
    @Test func overPullBumpsUnderflowCounter() {
        let state = AUChainRenderState(
            nodes: [.init(rawRenderBlock: overPullStub, latencySamples: 0)],
            sampleRate: testSampleRate
        )
        for block in 0..<3 {
            var buffer = makeSine(frames: 512, startFrame: block * 512)
            #expect(render(state, &buffer) == true)
        }
        let diag = state.diagnosticsSnapshot()[0]
        #expect(diag.underflowCount == 3)
        // Over-pull still consumed everything provided — not underconsumption.
        #expect(diag.underconsumptionCount == 0)
        #expect(diag.consecutiveMismatchCycles == 3)
    }

    // Gate case: consuming less than provided bumps the underconsumption counter.
    @Test func shortServeBumpsUnderconsumptionCounter() {
        let state = AUChainRenderState(
            nodes: [.init(rawRenderBlock: shortServeStub, latencySamples: 0)],
            sampleRate: testSampleRate
        )
        for block in 0..<3 {
            var buffer = makeSine(frames: 512, startFrame: block * 512)
            #expect(render(state, &buffer) == true)
        }
        let diag = state.diagnosticsSnapshot()[0]
        #expect(diag.underconsumptionCount == 3)
        #expect(diag.underflowCount == 0)
        #expect(diag.consecutiveMismatchCycles == 3)
    }

    // Contract: multiple partial pulls summing to ≤ frameCount are served in
    // order with no underflow and no underconsumption.
    @Test func multiplePartialPullsAreServed() {
        // Pulls twice (half each) into the output ABL at the correct offsets.
        let twoPullStub: AUChainRawRenderBlock = { _, tsPtr, frameCount, _, outputData, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            let half = frameCount / 2
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            var pullFlags = AudioUnitRenderActionFlags()
            let floatSize = MemoryLayout<Float>.size

            // First half straight into the output buffers.
            let originalData = (abl[0].mData, abl[1].mData)
            abl[0].mDataByteSize = UInt32(Int(half) * floatSize)
            abl[1].mDataByteSize = UInt32(Int(half) * floatSize)
            _ = withUnsafeMutablePointer(to: &pullFlags) { pull($0, tsPtr, half, 0, outputData) }

            // Second half at the halfway offset.
            abl[0].mData = originalData.0!.advanced(by: Int(half) * floatSize)
            abl[1].mData = originalData.1!.advanced(by: Int(half) * floatSize)
            abl[0].mDataByteSize = UInt32(Int(half) * floatSize)
            abl[1].mDataByteSize = UInt32(Int(half) * floatSize)
            _ = withUnsafeMutablePointer(to: &pullFlags) { pull($0, tsPtr, half, 0, outputData) }

            // Restore the ABL so the host reads the full buffers back.
            abl[0].mData = originalData.0
            abl[1].mData = originalData.1
            abl[0].mDataByteSize = UInt32(Int(frameCount) * floatSize)
            abl[1].mDataByteSize = UInt32(Int(frameCount) * floatSize)
            return noErr
        }

        let state = AUChainRenderState(
            nodes: [.init(rawRenderBlock: twoPullStub, latencySamples: 0)],
            sampleRate: testSampleRate
        )
        var buffer = makeSine(frames: 512)
        let reference = buffer
        #expect(render(state, &buffer) == true)

        // Passthrough via two partial pulls must reconstruct the input exactly.
        #expect(buffer == reference)
        let diag = state.diagnosticsSnapshot()[0]
        #expect(diag.underflowCount == 0)
        #expect(diag.underconsumptionCount == 0)
        #expect(diag.consecutiveMismatchCycles == 0)
    }

    // Gate case: NaN output is scrubbed to silence, counted, and never reaches
    // the output buffer; a clean cycle resets the strike counter.
    @Test func nanOutputIsScrubbedAndCounted() {
        let toggle = NaNToggle()
        let state = AUChainRenderState(
            nodes: [.init(rawRenderBlock: nanStub(toggle), latencySamples: 0)],
            sampleRate: testSampleRate
        )

        var buffer = makeSine(frames: 512)
        #expect(render(state, &buffer) == true)
        for sample in buffer {
            #expect(sample.isFinite)
            #expect(sample == 0)  // single-node chain: poisoned output slice zeroed
        }
        #expect(state.diagnosticsSnapshot()[0].nanStrikes == 1)

        var second = makeSine(frames: 512)
        #expect(render(state, &second) == true)
        #expect(state.diagnosticsSnapshot()[0].nanStrikes == 2)

        // Clean cycle resets strikes and audio flows again.
        toggle.emitNaN = false
        var third = makeSine(frames: 512, startFrame: 1024)
        let reference = third
        #expect(render(state, &third) == true)
        #expect(third == reference)  // clean pull-through passthrough
        #expect(state.diagnosticsSnapshot()[0].nanStrikes == 0)
    }

    // Gate case: frameCount > 4096 is processed in slices, never bypassed.
    @Test func oversizedCallbackIsProcessedInSlices() {
        let state = AUChainRenderState(
            nodes: [.init(rawRenderBlock: gainStub(0.5), latencySamples: 0)],
            sampleRate: testSampleRate
        )
        let frames = 10_000
        var buffer = makeSine(frames: frames)
        let dry = buffer

        #expect(render(state, &buffer) == true)

        // Every sample — including those beyond the first 4096-frame slice —
        // must be scaled by the node. Exact: memcpy + float multiply by 0.5.
        for i in 0..<buffer.count {
            #expect(buffer[i] == dry[i] * 0.5)
        }
        let diag = state.diagnosticsSnapshot()[0]
        #expect(diag.underflowCount == 0)
        #expect(diag.underconsumptionCount == 0)
    }

    // E1 mirror primitive: retained wet output copies into subsequent buffers,
    // min-length with zero-fill for any excess.
    @Test func mirrorCopyMatchesLastRenderAndZeroFills() {
        let state = AUChainRenderState(
            nodes: [.init(rawRenderBlock: gainStub(0.5), latencySamples: 0)],
            sampleRate: testSampleRate
        )
        let frames = 10_000
        var buffer = makeSine(frames: frames)
        #expect(render(state, &buffer) == true)

        // Larger destination: full copy + zero-filled tail.
        let largerFrames = 12_000
        var mirrored = [Float](repeating: -1, count: largerFrames * 2)
        mirrored.withUnsafeMutableBufferPointer {
            state.copyLastRenderOutput(into: $0.baseAddress!, frameCount: largerFrames)
        }
        for i in 0..<(frames * 2) {
            #expect(mirrored[i] == buffer[i])
        }
        for i in (frames * 2)..<(largerFrames * 2) {
            #expect(mirrored[i] == 0)
        }

        // Smaller destination: min-length copy.
        var small = [Float](repeating: -1, count: 100 * 2)
        small.withUnsafeMutableBufferPointer {
            state.copyLastRenderOutput(into: $0.baseAddress!, frameCount: 100)
        }
        for i in 0..<(100 * 2) {
            #expect(small[i] == buffer[i])
        }
    }

    // Two-node chain through the ping-pong scratch: gains compose in order.
    @Test func twoNodeChainComposesThroughPingPongScratch() {
        let state = AUChainRenderState(
            nodes: [
                .init(rawRenderBlock: gainStub(0.5), latencySamples: 0),
                .init(rawRenderBlock: gainStub(2.0), latencySamples: 0),
            ],
            sampleRate: testSampleRate
        )
        var buffer = makeSine(frames: 512)
        let dry = buffer
        #expect(render(state, &buffer) == true)
        for i in 0..<buffer.count {
            #expect(buffer[i] == dry[i] * 0.5 * 2.0)
        }
    }
}
