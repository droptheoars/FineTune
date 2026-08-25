// FineTune/Audio/AUChain/AUChainRenderState.swift
import Accelerate
import AudioToolbox
import Foundation
import os

// MARK: - Threading Model
//
// AUChainRenderState is the RT-facing, immutable render plan for a per-app AU
// effect chain (spec §2.3). It bridges two execution domains:
//
// 1. **Main thread / @MainActor (build time)**: init and deinit only.
//    - The owner (AppAUChain) constructs a new instance for every chain edit,
//      publishes it to the tap via atomic pointer swap + OSMemoryBarrier, and
//      defer-releases the old instance after a 0.5s grace period (same idiom
//      as BiquadProcessor.swapSetup). deinit assumes the RT thread has moved
//      on — the owner MUST wait out the grace period before dropping the last
//      reference, and before deallocateRenderResources on any member AU (E15).
//    - diagnosticsSnapshot() may be called from any non-RT thread (allocates).
//
// 2. **HAL I/O thread (real-time)**: render() and copyLastRenderOutput() only.
//    - MUST NOT allocate, block, log, or call ObjC. Allowed on this path:
//      invoking the stored ObjC render/pull blocks (function-pointer calls),
//      vDSP_ctoz/vDSP_ztoc, memcpy/memset, os_unfair_lock_trylock/unlock
//      (never blocks), aligned atomic loads/stores.
//    - Forbidden: any AUAudioUnit property access, KVC/KVO, fullState, format
//      objects, alloc/dealloc of render resources, Swift/ObjC bridging.
//
// **Why raw @convention(block) types**: the Swift-bridged `AUAudioUnit.renderBlock`
// property returns a thick Swift closure; invoking it re-bridges the pull-block
// argument to a new ObjC block on EVERY call — measured at exactly 1 malloc per
// render, which violates the no-allocation rule. NodeSpec(audioUnit:) instead
// extracts the AU's original ObjC block object once at build time (KVC) and
// stores it as a raw `@convention(block)` value; the pull block is created once
// per node as a real block. Measured: 0 mallocs across 1000 renders.
//
// **Gate**: the os_unfair_lock is used ONLY via trylock/unlock within a single
// render() invocation. It exists to close the crossfade-promotion race (§C):
// if two HAL callbacks overlap for ~one buffer, the loser passes its buffer
// through dry (render() returns false; the buffer is NOT zeroed).
//
// **Once-per-callback mirror contract (E1)**: stacked mirroring aggregates
// deliver one identical stereo buffer per sub-device. The caller must invoke
// render() exactly ONCE per HAL callback — on the first eligible buffer — or
// time-based effects run at 2×. For every subsequent eligible buffer in the
// SAME callback, call copyLastRenderOutput(into:frameCount:), which memcpys
// the retained wet result of the render that just completed (min-length, with
// zero-fill for any excess — a last-resort fallback; the retained store holds
// up to 16384 frames, comfortably above any real HAL callback). Calling it
// from a different callback than the one that rendered yields stale audio;
// sequencing is the caller's responsibility (T4).
//
// **Pull contract (§2.3)**: each node's pull block serves that node's input
// scratch at a per-cycle read offset. Multiple partial pulls summing to
// ≤ providedFrames are served in order; a pull past the provided frames
// zero-fills the shortfall and bumps the node's underflow counter; a cycle
// that consumes less than provided bumps the underconsumption counter.
// Counters are plain nonisolated(unsafe)-style fields read from MainActor via
// aligned loads (no locking) — sustained-mismatch detection (§D, ≥10
// consecutive cycles) reads consecutiveMismatchCycles or counter deltas.
//
// **NaN scrub**: after each node renders, sample 0 of both channels is checked;
// NaN/inf (or a non-noErr render status) zeroes that node's output slice for
// the cycle and bumps nanStrikes; a clean cycle resets nanStrikes to 0.

/// Raw ObjC-block form of `AURenderPullInputBlock`. Values of this type ARE the
/// block object — invoking one is a function-pointer call with no per-call
/// bridging or allocation.
typealias AUChainRawPullBlock = @convention(block) (
    UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    UnsafePointer<AudioTimeStamp>,
    AUAudioFrameCount,
    Int,
    UnsafeMutablePointer<AudioBufferList>
) -> AUAudioUnitStatus

/// Raw ObjC-block form of `AURenderBlock`. See `AUChainRawPullBlock`.
typealias AUChainRawRenderBlock = @convention(block) (
    UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    UnsafePointer<AudioTimeStamp>,
    AUAudioFrameCount,
    Int,
    UnsafeMutablePointer<AudioBufferList>,
    AUChainRawPullBlock?
) -> AUAudioUnitStatus

/// RT-facing immutable render plan for one AU effect chain.
/// Topology (nodes, scratch, latency) is fixed at init; only per-cycle
/// bookkeeping and diagnostic counters mutate afterward.
final class AUChainRenderState: @unchecked Sendable {

    /// Deinterleaved scratch capacity per channel; callbacks larger than this
    /// are processed in slices (E11 — never silently bypassed). Matches the
    /// `maximumFramesToRender = 4096` every member AU is configured with.
    static let sliceCapacity = 4096

    /// Retained interleaved wet-output capacity in frames (E1 mirror store).
    /// Sized to comfortably exceed any real HAL callback (~128 KB).
    static let mirrorCapacityFrames = 16384

    // MARK: - Build-time inputs

    /// One chain slot, captured at build time on MainActor. No AUAudioUnit
    /// property is ever touched on the RT path — everything RT needs is
    /// extracted here.
    struct NodeSpec {
        let rawRenderBlock: AUChainRawRenderBlock
        let latencySamples: Int

        /// Capture from a ready AU (after `allocateRenderResources()`).
        /// Extracts the AU's original ObjC render block object via KVC —
        /// see the file header for why the bridged `renderBlock` property
        /// must not be used on the RT path.
        init(audioUnit: AUAudioUnit, latencySamples: Int) {
            // `renderBlock` is a declared ObjC property; KVC returns the block
            // object itself (__NSMallocBlock__). A block value and AnyObject
            // share representation, so the bitcast is a supported reinterpret.
            if let blockObject = audioUnit.value(forKey: "renderBlock") {
                self.rawRenderBlock = unsafeBitCast(blockObject as AnyObject, to: AUChainRawRenderBlock.self)
            } else {
                // Should be unreachable; guards against a future macOS renaming
                // the property. Degraded mode: wrap the bridged closure — audio
                // keeps working, at the cost of ~1 small malloc per render call
                // (the bridging cost the raw path exists to avoid). Loud in the
                // log, not a crash on a user's machine at chain-build time.
                Logger(subsystem: "com.finetuneapp.FineTune", category: "AUChainRenderState")
                    .fault("renderBlock unavailable via KVC — falling back to bridged block (allocates on the RT path)")
                let bridged = audioUnit.renderBlock
                self.rawRenderBlock = { actionFlags, ts, frameCount, bus, abl, pull in
                    bridged(actionFlags, ts, frameCount, bus, abl, pull)
                }
            }
            self.latencySamples = latencySamples
        }

        /// Direct block injection (tests / stub nodes).
        init(rawRenderBlock: @escaping AUChainRawRenderBlock, latencySamples: Int) {
            self.rawRenderBlock = rawRenderBlock
            self.latencySamples = latencySamples
        }
    }

    /// Snapshot of one node's diagnostic counters (MainActor polling, §D/§E).
    struct NodeDiagnostics: Sendable {
        let latencySamples: Int
        let nanStrikes: Int32
        let underflowCount: Int64
        let underconsumptionCount: Int64
        let consecutiveMismatchCycles: Int32
    }

    // MARK: - Per-node RT state

    /// Plain-old-data bookkeeping mutated on the RT thread and read from
    /// MainActor via aligned loads (atomic on ARM64/x86-64, per the
    /// nonisolated(unsafe) doctrine in ProcessTapController.swift).
    private struct NodeRTState {
        var underflowCount: Int64 = 0
        var underconsumptionCount: Int64 = 0
        var nanStrikes: Int32 = 0
        var consecutiveMismatchCycles: Int32 = 0
        // Per-cycle pull bookkeeping — valid only within one render-block invocation.
        var providedFrames: Int32 = 0
        var readOffset: Int32 = 0
        var servedFrames: Int32 = 0
    }

    // LIFETIME of pull-block captures (scratch pointers + the rt pointer below):
    // everything a pull block touches shares this state's lifetime, and that is
    // sufficient because a pull block can never execute after this state is
    // released. Mechanism: AURenderPullInputBlock is a per-invocation parameter
    // of the render block — the AU pulls input only while servicing the render
    // call that passed it. An AU (or the v2 bridge) may RETAIN a pull block
    // between calls, but it always INVOKES the one passed to the current call:
    // verified against Apple's v2 bridge (AUDelay, 200 renders alternating two
    // marker blocks — zero stale invocations), and any implementation cached
    // otherwise would misroute input for every host that creates its pull block
    // per call, which Swift's bridged property does for typical hosts. render()
    // itself only runs while the owner keeps this state published, and the
    // owner's 0.5s grace (§2.2/E15) fences deinit past the last in-flight call.
    private final class Node {
        let renderBlock: AUChainRawRenderBlock
        let pullBlock: AUChainRawPullBlock
        let latencySamples: Int
        /// Heap-allocated so the pull block can capture a stable pointer
        /// without capturing the Node (which would be a retain cycle).
        let rt: UnsafeMutablePointer<NodeRTState>
        /// Output scratch (the ping-pong buffer of opposite parity to the input).
        let outL: UnsafeMutablePointer<Float>
        let outR: UnsafeMutablePointer<Float>
        /// Preallocated output ABL handed to the render block each cycle.
        let abl: UnsafeMutableAudioBufferListPointer

        init(
            renderBlock: @escaping AUChainRawRenderBlock,
            pullBlock: @escaping AUChainRawPullBlock,
            latencySamples: Int,
            rt: UnsafeMutablePointer<NodeRTState>,
            outL: UnsafeMutablePointer<Float>,
            outR: UnsafeMutablePointer<Float>
        ) {
            self.renderBlock = renderBlock
            self.pullBlock = pullBlock
            self.latencySamples = latencySamples
            self.rt = rt
            self.outL = outL
            self.outR = outR
            self.abl = AudioBufferList.allocate(maximumBuffers: 2)
        }

        deinit {
            rt.deinitialize(count: 1)
            rt.deallocate()
            // AudioBufferList.allocate uses malloc under the hood.
            free(abl.unsafeMutablePointer)
        }
    }

    // MARK: - Immutable topology

    let builtSampleRate: Double
    /// Σ node latencies, computed once at build (§E latency display).
    let totalLatencySamples: Int
    var nodeCount: Int { nodes.count }

    private let nodes: [Node]

    // Ping-pong deinterleaved stereo scratch: node i reads parity i&1, writes
    // the other. One contiguous allocation: [s0L | s0R | s1L | s1R].
    private let scratchBase: UnsafeMutablePointer<Float>
    private let s0L: UnsafeMutablePointer<Float>
    private let s0R: UnsafeMutablePointer<Float>
    private let s1L: UnsafeMutablePointer<Float>
    private let s1R: UnsafeMutablePointer<Float>

    /// Retained interleaved wet output of the most recent successful render (E1).
    private let mirrorStore: UnsafeMutablePointer<Float>

    /// Preallocated timestamp / flags passed to render blocks (spec §2.3).
    private let timestamp: UnsafeMutablePointer<AudioTimeStamp>
    private let flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>

    /// Ownership gate — trylock/unlock within one callback invocation ONLY (§C).
    /// Heap-allocated so the lock has a stable address.
    private let gate: UnsafeMutablePointer<os_unfair_lock>

    // MARK: - RT-mutable state

    /// Running sample timeline, advanced by frameCount per successful render.
    private nonisolated(unsafe) var _sampleTime: Int64 = 0
    /// Frames currently valid in mirrorStore (0 until the first successful render).
    private nonisolated(unsafe) var _lastRenderFrames: Int = 0

    // MARK: - Init / Deinit (MainActor, build time)

    /// - Parameters:
    ///   - specs: ready slots in signal order. Render blocks must have been
    ///     captured AFTER `allocateRenderResources()` succeeded (§A), and the
    ///     owner must keep the AUs allocated for this instance's lifetime
    ///     plus the 0.5s swap grace period (E15).
    ///   - sampleRate: the tap's nominal rate this chain was built for. Used
    ///     by the owner to detect stale builds (§E); not read on the RT path.
    init(nodes specs: [NodeSpec], sampleRate: Double) {
        builtSampleRate = sampleRate
        totalLatencySamples = specs.reduce(0) { $0 + $1.latencySamples }

        let cap = Self.sliceCapacity
        // 4 parity regions + one region of tail padding: an AU that over-pulls
        // into host-provided scratch (nil-mData branch) AND ignores the
        // reported mDataByteSize reads up to readOffset+requested ≤ 2×cap
        // frames past a region start (both bounded by maximumFramesToRender);
        // the pad keeps even that overread inside this allocation.
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 5 * cap)
        scratch.initialize(repeating: 0, count: 5 * cap)
        scratchBase = scratch
        let p0L = scratch
        let p0R = scratch + cap
        let p1L = scratch + 2 * cap
        let p1R = scratch + 3 * cap
        s0L = p0L
        s0R = p0R
        s1L = p1L
        s1R = p1R

        let mirror = UnsafeMutablePointer<Float>.allocate(capacity: Self.mirrorCapacityFrames * 2)
        mirror.initialize(repeating: 0, count: Self.mirrorCapacityFrames * 2)
        mirrorStore = mirror

        timestamp = .allocate(capacity: 1)
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        timestamp.initialize(to: ts)

        flags = .allocate(capacity: 1)
        flags.initialize(to: [])

        gate = .allocate(capacity: 1)
        gate.initialize(to: os_unfair_lock())

        var built: [Node] = []
        built.reserveCapacity(specs.count)
        for (index, spec) in specs.enumerated() {
            let inputIsParity0 = (index & 1) == 0
            let rt = UnsafeMutablePointer<NodeRTState>.allocate(capacity: 1)
            rt.initialize(to: NodeRTState())
            let pull = Self.makePullBlock(
                rt: rt,
                inL: inputIsParity0 ? p0L : p1L,
                inR: inputIsParity0 ? p0R : p1R,
                capacity: cap
            )
            built.append(Node(
                renderBlock: spec.rawRenderBlock,
                pullBlock: pull,
                latencySamples: spec.latencySamples,
                rt: rt,
                outL: inputIsParity0 ? p1L : p0L,
                outR: inputIsParity0 ? p1R : p0R
            ))
        }
        nodes = built
    }

    deinit {
        scratchBase.deallocate()
        mirrorStore.deallocate()
        timestamp.deallocate()
        flags.deallocate()
        gate.deallocate()
    }

    // MARK: - Pull block (built once per node; runs on the RT thread)

    /// Serves the node's fixed input scratch at the per-cycle read offset.
    /// Created once at build time as a real ObjC block — zero per-call bridging.
    private static func makePullBlock(
        rt: UnsafeMutablePointer<NodeRTState>,
        inL: UnsafeMutablePointer<Float>,
        inR: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> AUChainRawPullBlock {
        return { _, _, requestedCount, _, inputData in
            let requested = Int(requestedCount)
            let provided = Int(rt.pointee.providedFrames)
            let readOffset = Int(rt.pointee.readOffset)
            let available = max(0, provided - readOffset)
            let serve = min(requested, available)
            if serve < requested {
                rt.pointee.underflowCount &+= 1
            }

            let abl = UnsafeMutableAudioBufferListPointer(inputData)
            let floatSize = MemoryLayout<Float>.size
            var buffer = 0
            let bufferCount = min(2, abl.count)
            while buffer < bufferCount {
                let src = (buffer == 0 ? inL : inR) + readOffset
                if let dst = abl[buffer].mData {
                    // AU supplied its own input buffer (the common case, per
                    // probing Apple's v2 bridge): copy what we have, zero-fill
                    // the shortfall, clamped to the buffer's capacity.
                    let dstCap = Int(abl[buffer].mDataByteSize) / floatSize
                    let copyCount = min(serve, dstCap)
                    let fillCount = min(requested, dstCap)
                    if copyCount > 0 {
                        memcpy(dst, src, copyCount * floatSize)
                    }
                    if fillCount > copyCount {
                        memset(dst.advanced(by: copyCount * floatSize), 0, (fillCount - copyCount) * floatSize)
                    }
                    abl[buffer].mDataByteSize = UInt32(fillCount * floatSize)
                } else {
                    // AU asked the host to provide the buffer: point it at our
                    // fixed scratch. Zero-fill in place for any over-pull
                    // (scratch past `provided` holds no live data this cycle).
                    let clamped = min(requested, capacity - readOffset)
                    if clamped > serve {
                        memset(src + serve, 0, (clamped - serve) * floatSize)
                    }
                    abl[buffer].mData = UnsafeMutableRawPointer(src)
                    abl[buffer].mDataByteSize = UInt32(max(0, clamped) * floatSize)
                }
                buffer += 1
            }

            rt.pointee.readOffset = Int32(readOffset + serve)
            rt.pointee.servedFrames &+= Int32(serve)
            return noErr
        }
    }

    // MARK: - RT entry points (HAL I/O thread ONLY)

    /// Render the chain in place over an interleaved stereo Float32 buffer.
    /// Returns `false` when the buffer passed through dry (gate contention or
    /// empty chain) — the buffer is NOT modified and NOT zeroed in that case.
    ///
    /// RT-safe: no allocation, no blocking lock, no ObjC messaging, no logging.
    func render(interleavedStereo: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool {
        guard frameCount > 0, !nodes.isEmpty else { return false }
        guard os_unfair_lock_trylock(gate) else { return false }

        let floatSize = MemoryLayout<Float>.size
        let nodeCount = nodes.count
        var offset = 0
        while offset < frameCount {
            let slice = min(frameCount - offset, Self.sliceCapacity)
            let basePtr = interleavedStereo + offset * 2

            // Deinterleave the slice into parity-0 scratch.
            var inSplit = DSPSplitComplex(realp: s0L, imagp: s0R)
            basePtr.withMemoryRebound(to: DSPComplex.self, capacity: slice) {
                vDSP_ctoz($0, 2, &inSplit, 1, vDSP_Length(slice))
            }

            timestamp.pointee.mSampleTime = Double(_sampleTime &+ Int64(offset))

            for index in 0..<nodeCount {
                let node = nodes[index]
                let rt = node.rt

                // Rebind the output ABL to this node's fixed scratch — the AU
                // may have substituted its own pointers last cycle.
                node.abl.unsafeMutablePointer.pointee.mNumberBuffers = 2
                node.abl[0] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(slice * floatSize),
                    mData: UnsafeMutableRawPointer(node.outL)
                )
                node.abl[1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(slice * floatSize),
                    mData: UnsafeMutableRawPointer(node.outR)
                )

                rt.pointee.providedFrames = Int32(slice)
                rt.pointee.readOffset = 0
                rt.pointee.servedFrames = 0
                let underflowsBefore = rt.pointee.underflowCount

                flags.pointee = []
                let status = node.renderBlock(
                    flags,
                    UnsafePointer(timestamp),
                    AUAudioFrameCount(slice),
                    0,
                    node.abl.unsafeMutablePointer,
                    node.pullBlock
                )

                // AUs may render into their own internal buffers and swap the
                // ABL's mData; copy back so the next node's fixed pull pointers
                // stay valid.
                if let data = node.abl[0].mData, data != UnsafeMutableRawPointer(node.outL) {
                    memcpy(node.outL, data, slice * floatSize)
                }
                if let data = node.abl[1].mData, data != UnsafeMutableRawPointer(node.outR) {
                    memcpy(node.outR, data, slice * floatSize)
                }

                // Rate-mismatch bookkeeping (§D).
                var mismatch = rt.pointee.underflowCount != underflowsBefore
                if Int(rt.pointee.servedFrames) < slice {
                    rt.pointee.underconsumptionCount &+= 1
                    mismatch = true
                }
                if mismatch {
                    rt.pointee.consecutiveMismatchCycles &+= 1
                } else {
                    rt.pointee.consecutiveMismatchCycles = 0
                }

                // NaN/inf scrub (§E) — sample 0 of both channels; a failed
                // render status is scrubbed the same way (output undefined).
                if status != noErr || !node.outL[0].isFinite || !node.outR[0].isFinite {
                    memset(node.outL, 0, slice * floatSize)
                    memset(node.outR, 0, slice * floatSize)
                    rt.pointee.nanStrikes &+= 1
                } else {
                    rt.pointee.nanStrikes = 0
                }
            }

            // Interleave the final parity scratch back in place.
            let finalIsParity0 = (nodeCount & 1) == 0
            var outSplit = DSPSplitComplex(
                realp: finalIsParity0 ? s0L : s1L,
                imagp: finalIsParity0 ? s0R : s1R
            )
            basePtr.withMemoryRebound(to: DSPComplex.self, capacity: slice) {
                vDSP_ztoc(&outSplit, 1, $0, 2, vDSP_Length(slice))
            }

            offset += slice
        }

        _sampleTime &+= Int64(frameCount)

        // Retain the wet result for mirrored sub-device buffers (E1).
        let mirrorFrames = min(frameCount, Self.mirrorCapacityFrames)
        memcpy(mirrorStore, interleavedStereo, mirrorFrames * 2 * floatSize)
        _lastRenderFrames = mirrorFrames

        os_unfair_lock_unlock(gate)
        return true
    }

    /// Copy the retained wet output of the most recent successful render into
    /// an interleaved stereo buffer — the E1 mirror primitive. Min-length with
    /// zero-fill for any excess. RT-safe (memcpy/memset only).
    ///
    /// Contract: call only from the SAME HAL callback in which render() just
    /// returned true, for the second and later mirrored output buffers. Not
    /// gate-protected — during the one-buffer crossfade-promotion race a
    /// concurrent render() could tear this copy; bounded to one glitchy
    /// mirrored buffer, same magnitude as the accepted §C dry-buffer race.
    func copyLastRenderOutput(into interleavedStereo: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let floatSize = MemoryLayout<Float>.size
        let copyFrames = min(frameCount, _lastRenderFrames)
        if copyFrames > 0 {
            memcpy(interleavedStereo, mirrorStore, copyFrames * 2 * floatSize)
        }
        if copyFrames < frameCount {
            memset(interleavedStereo + copyFrames * 2, 0, (frameCount - copyFrames) * 2 * floatSize)
        }
    }

    // MARK: - Diagnostics (any non-RT thread; allocates)

    /// Snapshot of every node's counters, in signal order. Values are aligned
    /// loads of RT-written fields — momentarily stale, never torn.
    func diagnosticsSnapshot() -> [NodeDiagnostics] {
        return nodes.map { node in
            let rt = node.rt
            return NodeDiagnostics(
                latencySamples: node.latencySamples,
                nanStrikes: rt.pointee.nanStrikes,
                underflowCount: rt.pointee.underflowCount,
                underconsumptionCount: rt.pointee.underconsumptionCount,
                consecutiveMismatchCycles: rt.pointee.consecutiveMismatchCycles
            )
        }
    }
}
