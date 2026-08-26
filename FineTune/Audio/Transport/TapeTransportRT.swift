// FineTune/Audio/Transport/TapeTransportRT.swift
import Accelerate
import Darwin.C  // OSMemoryBarrier
import Foundation

// MARK: - Threading Model
//
// TapeTransportRT is the RT-facing ring buffer + tape read head for one app's
// transport (Phase 2 spec §2.3). Unlike AUChainRenderState's immutable plans,
// this object has legitimately mutable RT state (write clock, read position),
// so the split is fields, not pointer swaps (§2.2):
//
// 1. **Main thread / @MainActor (control side)**: command setters only —
//    setTargetRate / requestSeek / requestLive / setLoop / clearLoop. Commands
//    are aligned single-word atomic stores; the seek pair is published
//    seqlock-style (payload, barrier, generation last) and consumed by the RT
//    thread at most once per callback, latest generation wins (E27).
//    init/deinit run off-main on the owner's utility queue (§2.2 — the ring is
//    up to ~346 MB; alloc+zero on MainActor would stall the popup, E23).
//    diagnosticsSnapshot() may be called from any non-RT thread.
//
// 2. **HAL I/O thread (real-time)**: writeAndRender / writeSilence /
//    copyLastOutput only, primary callback only (E17), once per callback (E16).
//    MUST NOT allocate, block, log, or call ObjC. Allowed on this path:
//    memcpy/memset, vDSP_maxmgv, libm (sinf/cosf/exp-free — pure compute),
//    aligned atomic loads/stores, OSMemoryBarrier. There is deliberately NO
//    lock, not even a trylock: write clock and read position have exactly one
//    writer (the primary callback), except across a crossfade promotion, where
//    the old primary's in-flight callback and the promoted one can both be
//    inside writeAndRender once. That window is accepted (§2.3/E17), and the
//    review traced it more precisely than "one blended buffer" (T10/I2):
//      - the two writeToRing calls can advance `_writeFrames` twice with
//        near-identical content — one duplicated ~10 ms span in the timeline;
//      - `_readAbsQ`/`_readRingQ` are updated as a NON-ATOMIC PAIR, so racing
//        read-modify-writes can leave them desynchronized by up to one buffer:
//        a constant playback offset that persists until the next seek, LIVE or
//        loop jump calls setPrimary (which re-derives ring from abs);
//      - the fade counters for that one callback can tear.
//    No memory unsafety in any of it: both positions stay clamped in range,
//    interpolatedSample cannot read out of bounds, and the conditional ±capacity
//    wrap survives a lost update. Bounded, rare, self-healing — accepted, but
//    do not restate it as one blended buffer.
//
// **Write discipline (§2.3)**: publish `_writeReserved` (the span about to be
// overwritten) FIRST, then memcpy samples into the ring, then OSMemoryBarrier(),
// then advance `_writeFrames` — a concurrent exporter or UI reader never sees an
// index covering unwritten audio, and never mistakes an in-flight overwrite for
// intact history (the clock lags the destruction; the reservation leads it).
// Both indices are needed: one bounds what is READABLE, the other what is
// already GONE. Ring index is computed
// once per callback (`writeFrames % capacityFrames`); writes split at the
// physical wrap into at most two block copies — no per-frame modulo (E31).
//
// **Why Q40.24 fixed point**: the read position advances by
// `step = Int64((Double(rate) * 2^24).rounded())` per output frame. Fixed
// point is deterministic — property tests assert exact positions, not
// tolerances; r = 1.0 is `step = 2^24`, an integer advance with zero drift
// against the write clock. The Float→Double widening is lossless and the
// ×2^24 is an exact exponent shift, so the step is bit-determined by the rate.
// Q40.24 overflows after 2^39 frames ≈ 289 years; rate resolution 2^-24.
// Two parallel accumulators avoid per-frame modulo on the read path too:
// `_readAbsQ` (absolute, for window math) and `_readRingQ` (wrapped into the
// ring by conditional ± capacity — |step| ≤ 4·2^24 ≪ capacityQ).
//
// **Interpolation**: 4-point Catmull-Rom on the fractional position, evaluated
// in Horner form with c0 = p1, so an integer position (frac == 0) reproduces
// the stored sample BIT-EXACTLY — the rewind-by-k-at-rate-1.0 exactness
// guarantee (§7.2). frac == 0 short-circuits to a direct read.
//
// **Valid window**: [writeFrames − capacity + margin(1 s), writeFrames − 4].
// The −4 keeps the cubic kernel's lookahead off unwritten frames (E26).
//
// **Horizon collision (E18), skip-free by construction**: the window's
// trailing edge advances in callback-sized jumps, so clamping the read head to
// it after the fact would skip (1−r)·N frames per bind — exactly the §D
// jump-cut artifact. Instead the transport forces the EFFECTIVE rate to 1.0
// whenever the read head is within `horizonGuardFrames` of the trailing edge
// and the requested rate is < 1.0: the gap then stays constant and no frame is
// ever skipped. `targetRate` is never overwritten; audible consequence is the
// spec's pitch snap to 1.0 at the horizon. A stopped transport (rate snapped
// to 0) at the horizon holds silence while the window drags its position.
//
// **One jump primitive (§2.3)**: every discontinuity — seek 20 ms, LIVE 50 ms,
// loop wrap 10 ms, and the Q2 auto-pin when fast-forward reaches the live
// edge — is an equal-power crossfade. A fade side is either a ring read head
// or the caller's live buffer: leaving live fades OUT of the buffer's own
// samples, returning to live fades INTO them, so the moment the LIVE fade
// completes the output is bit-identical to passthrough and pinning is
// seamless (the ring's own live edge sits behind writeFrames − 4 and cannot
// be read seamlessly, E26). Jumps are atomic: a pending command is consumed
// only when no fade is active, so overlapping scrub seeks coalesce
// (latest-generation-wins) into back-to-back 20 ms hops instead of ever
// dropping a half-faded side mid-blend.
//
// **Pinned-live is not "resample at 1.0"**: the buffer is written to the ring
// and returned UNTOUCHED — the zero-added-latency proof (§4) is structural.
//
// **Stop-fade**: output gain ramps linearly to zero below |effective rate| <
// 0.05, so a braking tape fades out instead of holding the DC value of the
// sample it stopped on, and resuming fades back in. Rate changes go through a
// per-frame one-pole ramp toward targetRate (coefficient published by the
// setter; ~20 ms default, stop/brake constants below) with a snap once within
// 5e-4 — after the snap the step is exact again.
//
// **Mirror store (E16)**: retained interleaved copy of the last transport
// output, same contract as AUChainRenderState.copyLastRenderOutput — the
// caller invokes writeAndRender exactly once per HAL callback on the first
// eligible buffer and memcpys later mirrored buffers via copyLastOutput, but
// only when writeAndRender returned true (live passthrough leaves mirrored
// buffers already identical by construction).

/// RT-facing ring buffer + tape transport read head for one app (spec §2.3).
/// Owned by AppTapeTransport, published to the tap by atomic pointer swap with
/// the 0.5 s release grace (the setAUChain idiom); the tap never owns it.
final class TapeTransportRT: @unchecked Sendable {

    // MARK: - Constants

    /// Retained interleaved output capacity in frames (E16 mirror store),
    /// matching AUChainRenderState.mirrorCapacityFrames.
    static let mirrorCapacityFrames = 16384

    /// Rate ramp constants (§2.5) — the one place these live. Callers pass
    /// them to `setTargetRate(_:rampSeconds:)`; the mockup may retune.
    static let defaultRampSeconds: Double = 0.020
    static let stopRampSeconds: Double = 0.150
    static let brakeRampSeconds: Double = 0.800

    /// r ∈ [−4, +4] (§2.5); 0 = stopped.
    static let maxRate: Float = 4.0

    private static let qShift: Int64 = 24
    private static let oneQ: Int64 = 1 << 24
    private static let fracMask: Int64 = (1 << 24) - 1
    /// Smoothed rate snaps to target inside this — restores exact stepping.
    private static let rateSnapEpsilon: Float = 5e-4
    /// Below this |effective rate| the output gain fades linearly to zero.
    private static let stopFadeKnee: Float = 0.05

    private enum FadeKind: UInt8 {
        case none = 0
        /// Seek or loop wrap: both sides are ring read heads.
        case ringToRing = 1
        /// Leaving live: fade out of the caller's buffer, into the ring head.
        case fromLive = 2
        /// Returning to live (explicit or Q2 auto-pin): fade out of the ring
        /// head, into the caller's buffer; pin when complete.
        case toLive = 3
    }

    // MARK: - Immutable configuration

    let sampleRate: Double
    /// Exact ring capacity in frames — `minutes × 60 × rate`, never padded.
    let capacityFrames: Int
    /// Headroom between the window's trailing edge and the playable horizon;
    /// must exceed the largest HAL callback for E18 to stay skip-free.
    /// Injectable for tests with small rings.
    let horizonGuardFrames: Int
    /// 1 s writer-headroom margin above the physical trailing edge (§2.3).
    let marginFrames: Int
    let seekFadeFrames: Int
    let liveFadeFrames: Int
    let loopFadeFrames: Int

    /// Ring allocation size — asserted exact by the memory acceptance test.
    var allocatedRingBytes: Int { capacityFrames * 2 * MemoryLayout<Float>.size }

    private let ring: UnsafeMutablePointer<Float>
    private let mirrorStore: UnsafeMutablePointer<Float>
    private let capQ: Int64

    // MARK: - Command fields (MainActor writes, RT reads)

    private nonisolated(unsafe) var _targetRateBits: UInt32 = Float(1.0).bitPattern
    private nonisolated(unsafe) var _rateRampCoeffBits: UInt32 = 0
    private nonisolated(unsafe) var _loopStartFrames: Int64 = 0
    /// 0 = no loop (§2.5). Published end-first-to-zero so the RT thread only
    /// ever sees a disabled or fully-formed pair.
    private nonisolated(unsafe) var _loopEndFrames: Int64 = 0
    private nonisolated(unsafe) var _cmdPosFrames: Int64 = 0
    private nonisolated(unsafe) var _cmdKind: UInt8 = 0  // 0 = seek, 1 = live
    private nonisolated(unsafe) var _cmdGeneration: Int32 = 0

    // MARK: - RT-owned state (read from MainActor via aligned loads)

    /// Monotonic frames written since creation — the write clock.
    private nonisolated(unsafe) var _writeFrames: Int64 = 0
    /// Frames the in-flight callback is about to overwrite, published BEFORE a
    /// sample lands (§2.3). Runs one callback ahead of `_writeFrames` for the
    /// duration of a write; equal to it at rest. Read only by
    /// `copyRingWindow`'s post-copy re-check.
    private nonisolated(unsafe) var _writeReserved: Int64 = 0
    private nonisolated(unsafe) var _pinnedToLive: UInt8 = 1
    private nonisolated(unsafe) var _currentRate: Float = 1.0
    /// Absolute read position, Q40.24 — window math.
    private nonisolated(unsafe) var _readAbsQ: Int64 = 0
    /// Same position wrapped into the ring, Q40.24 — sample addressing.
    private nonisolated(unsafe) var _readRingQ: Int64 = 0
    private nonisolated(unsafe) var _shadowAbsQ: Int64 = 0
    private nonisolated(unsafe) var _shadowRingQ: Int64 = 0
    private nonisolated(unsafe) var _fadeKind: UInt8 = 0
    private nonisolated(unsafe) var _fadeDone: Int32 = 0
    private nonisolated(unsafe) var _fadeTotal: Int32 = 1
    private nonisolated(unsafe) var _consumedGeneration: Int32 = 0
    /// Frames currently valid in mirrorStore (0 until the first non-live render).
    private nonisolated(unsafe) var _lastOutputFrames: Int = 0
    /// Peak |sample| of the last processed buffer — VU/gate substitution (E19).
    private nonisolated(unsafe) var _lastOutputPeak: Float = 0
    private nonisolated(unsafe) var _atHorizon: UInt8 = 0
    private nonisolated(unsafe) var _loopDegraded: UInt8 = 0
    private nonisolated(unsafe) var _clampEventCount: Int64 = 0
    private nonisolated(unsafe) var _seeksConsumed: Int64 = 0

    // MARK: - Init / Deinit (owner's utility queue — NOT the RT thread)

    /// - Parameters:
    ///   - sampleRate: device rate the ring records at. A rate change discards
    ///     the transport entirely (E22) — there is no resample path.
    ///   - capacityFrames: exact ring length in frames.
    ///   - horizonGuardFrames: E18 guard zone; override only in tests.
    init(sampleRate: Double, capacityFrames: Int, horizonGuardFrames: Int = 4096) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        let margin = Int(sampleRate)  // 1 s (§2.3)
        precondition(
            capacityFrames > margin + horizonGuardFrames + 16,
            "ring too small to hold the valid window"
        )
        self.sampleRate = sampleRate
        self.capacityFrames = capacityFrames
        self.horizonGuardFrames = horizonGuardFrames
        self.marginFrames = margin
        self.seekFadeFrames = max(1, Int(sampleRate * 0.020))
        self.liveFadeFrames = max(1, Int(sampleRate * 0.050))
        self.loopFadeFrames = max(1, Int(sampleRate * 0.010))
        self.capQ = Int64(capacityFrames) << Self.qShift

        let ringCount = capacityFrames * 2
        let ringMemory = UnsafeMutablePointer<Float>.allocate(capacity: ringCount)
        ringMemory.initialize(repeating: 0, count: ringCount)
        self.ring = ringMemory

        let mirrorCount = Self.mirrorCapacityFrames * 2
        let mirrorMemory = UnsafeMutablePointer<Float>.allocate(capacity: mirrorCount)
        mirrorMemory.initialize(repeating: 0, count: mirrorCount)
        self.mirrorStore = mirrorMemory

        let coeff = Float(1.0 - exp(-1.0 / (sampleRate * Self.defaultRampSeconds)))
        self._rateRampCoeffBits = coeff.bitPattern
    }

    deinit {
        ring.deallocate()
        mirrorStore.deallocate()
    }

    // MARK: - Command setters (MainActor)

    /// Sets the requested tape rate, clamped to ±maxRate; 0 = stopped. The RT
    /// thread ramps toward it through a one-pole smoother — pass
    /// `stopRampSeconds` / `brakeRampSeconds` for the tape-stop feel (§2.5).
    func setTargetRate(_ rate: Float, rampSeconds: Double = TapeTransportRT.defaultRampSeconds) {
        let clamped = min(max(rate, -Self.maxRate), Self.maxRate)
        let coeff = Float(1.0 - exp(-1.0 / (sampleRate * max(rampSeconds, 0.001))))
        _rateRampCoeffBits = coeff.bitPattern
        OSMemoryBarrier()
        _targetRateBits = clamped.bitPattern
    }

    /// Requests playback from an absolute write-clock frame (unpins from live
    /// if needed), through the 20 ms jump crossfade. Coalesces: the RT thread
    /// consumes at most one pending command per callback, latest wins (E27).
    func requestSeek(toFrame frame: Int64) {
        publishCommand(kind: 0, positionFrames: max(0, frame))
    }

    /// Requests return to live passthrough through the 50 ms crossfade (§2.5).
    func requestLive() {
        publishCommand(kind: 1, positionFrames: 0)
    }

    /// Sets the loop region in absolute write-clock frames. Bounds are clamped
    /// into the valid window each callback; a region squeezed below twice the
    /// loop fade degrades to no-loop with the diagnostic flag set (§2.5).
    func setLoop(startFrame: Int64, endFrame: Int64) {
        guard startFrame >= 0, endFrame > startFrame else {
            clearLoop()
            return
        }
        _loopEndFrames = 0
        OSMemoryBarrier()
        _loopStartFrames = startFrame
        OSMemoryBarrier()
        _loopEndFrames = endFrame
    }

    func clearLoop() {
        _loopEndFrames = 0
    }

    /// Current write clock — MainActor uses this to compute seek targets
    /// ("rewind 10 s" = writtenFrames − 10 × rate) and export windows.
    var writtenFrames: Int64 { _writeFrames }

    private func publishCommand(kind: UInt8, positionFrames: Int64) {
        _cmdPosFrames = positionFrames
        _cmdKind = kind
        OSMemoryBarrier()
        _cmdGeneration &+= 1
    }

    // MARK: - Diagnostics (any non-RT thread)

    struct Diagnostics: Sendable {
        let isPinnedToLive: Bool
        let isAtHorizon: Bool
        let isLoopDegraded: Bool
        let writeFrames: Int64
        /// Absolute read position, Q40.24 — exactness tests assert this equal.
        let readPositionQ: Int64
        let lagFrames: Int64
        let clampEventCount: Int64
        let seeksConsumed: Int64
        let lastOutputPeak: Float
    }

    /// Aligned loads of RT-written fields — momentarily stale, never torn.
    func diagnosticsSnapshot() -> Diagnostics {
        let writeFrames = _writeFrames
        let positionQ = _readAbsQ
        let pinned = _pinnedToLive != 0
        return Diagnostics(
            isPinnedToLive: pinned,
            isAtHorizon: _atHorizon != 0,
            isLoopDegraded: _loopDegraded != 0,
            writeFrames: writeFrames,
            readPositionQ: positionQ,
            lagFrames: pinned ? 0 : max(0, writeFrames - (positionQ >> Self.qShift)),
            clampEventCount: _clampEventCount,
            seeksConsumed: _seeksConsumed,
            lastOutputPeak: _lastOutputPeak
        )
    }

    // MARK: - Non-RT window reader (export, E24)

    /// Copies `frameCount` interleaved stereo frames starting at absolute
    /// write-clock frame `startFrame` into `destination`, then re-checks the
    /// write clock. Returns false when that span was never readable, or when
    /// the writer overwrote any part of it *during* the copy — the copied
    /// bytes are then meaningless and the caller must discard them (E24).
    ///
    /// Any non-RT thread. Lock-free by construction and therefore invisible to
    /// the RT thread: it never blocks the writer, only itself. Mirror image of
    /// the write discipline in `writeToRing`: the writer publishes samples
    /// before the index, so every frame below the loaded `_writeFrames` is
    /// fully written; and it reserves the span it is about to overwrite before
    /// touching it, so the second load — of `_writeReserved` — catches a writer
    /// that lapped us mid-copy even while its own write is still in flight.
    func copyRingWindow(
        from startFrame: Int64,
        frameCount: Int,
        into destination: UnsafeMutablePointer<Float>
    ) -> Bool {
        guard frameCount > 0, frameCount <= capacityFrames, startFrame >= 0 else { return false }
        let endFrame = startFrame &+ Int64(frameCount)
        let writeFramesBefore = _writeFrames
        OSMemoryBarrier()
        // Never read past the write head (unwritten frames) or behind the
        // ring's physical trailing edge (already overwritten).
        guard endFrame <= writeFramesBefore,
              startFrame >= writeFramesBefore - Int64(capacityFrames) else { return false }

        let floatSize = MemoryLayout<Float>.size
        let startIndex = Int(startFrame % Int64(capacityFrames))
        let firstRegion = min(frameCount, capacityFrames - startIndex)
        memcpy(destination, ring + startIndex * 2, firstRegion * 2 * floatSize)
        if frameCount > firstRegion {
            memcpy(destination + firstRegion * 2, ring, (frameCount - firstRegion) * 2 * floatSize)
        }

        OSMemoryBarrier()
        // The writer advances while we copy; if it reached into this span the
        // copy is torn and the chunk is dropped from the export's head.
        // Re-checked against the RESERVATION, not the write clock: the clock
        // lags the frames the in-flight callback has already overwritten by up
        // to one callback, and checking it accepts torn copies of the last
        // callback's worth of frames above the trailing edge.
        return startFrame >= _writeReserved - Int64(capacityFrames)
    }

    // MARK: - RT entry points (HAL I/O thread, primary callback ONLY)

    /// RT entry point, once per callback (E16). Writes `frameCount` frames of
    /// `buffer` into the ring, then — when not pinned to live — replaces
    /// `buffer` with transport output. Returns true when the buffer was
    /// replaced (non-live), false when passthrough (live; buffer untouched).
    func writeAndRender(interleavedStereo buffer: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool {
        guard frameCount > 0 else { return false }
        writeToRing(buffer, frameCount: frameCount)
        // Jumps are atomic: consume a pending command only between fades.
        if _fadeKind == FadeKind.none.rawValue {
            consumeCommand()
        }
        if _pinnedToLive != 0 {
            updatePeak(buffer, frameCount: frameCount)
            return false
        }
        renderTransport(into: buffer, frameCount: frameCount)
        return true
    }

    /// E16 mirror primitive, same contract as AUChainRenderState's
    /// copyLastRenderOutput: min-length memcpy of the last non-live output,
    /// zero-fill for any excess. Call only from the SAME HAL callback in which
    /// writeAndRender just returned true.
    func copyLastOutput(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let floatSize = MemoryLayout<Float>.size
        let copyFrames = min(frameCount, _lastOutputFrames)
        if copyFrames > 0 {
            memcpy(buffer, mirrorStore, copyFrames * 2 * floatSize)
        }
        if copyFrames < frameCount {
            memset(buffer + copyFrames * 2, 0, (frameCount - copyFrames) * 2 * floatSize)
        }
    }

    /// Muted / force-silence path (E21): writes silence so the tape timeline
    /// stays continuous. Does not render and does not move the read head.
    func writeSilence(frameCount: Int) {
        guard frameCount > 0 else { return }
        writeToRing(nil, frameCount: frameCount)
    }

    // MARK: - Ring write (RT)

    /// memcpy/memset into ≤ 2 wrap-split regions, barrier, then advance the
    /// write clock (§2.3). `source == nil` writes silence.
    private func writeToRing(_ source: UnsafePointer<Float>?, frameCount: Int) {
        let floatSize = MemoryLayout<Float>.size
        let writeFrames = _writeFrames
        var frames = frameCount
        var sourceOffset = 0
        if frames > capacityFrames {
            // Pathological oversized callback: keep only the newest history.
            sourceOffset = frames - capacityFrames
            frames = capacityFrames
        }
        // Claim the span BEFORE overwriting it. `_writeFrames` alone cannot
        // tell a reader what has already been destroyed: samples are published
        // before the index, so between the memcpy and the store below the ring
        // already holds new audio while the clock still reports the old head.
        // A reader re-checking against the clock accepts that torn span (E24).
        // max(): during a crossfade promotion two callbacks can be in here at
        // once (see the header) — the reservation must never move backwards.
        _writeReserved = max(_writeReserved, writeFrames &+ Int64(frameCount))
        OSMemoryBarrier()
        let startIndex = Int((writeFrames &+ Int64(sourceOffset)) % Int64(capacityFrames))
        let firstRegion = min(frames, capacityFrames - startIndex)
        if let source {
            memcpy(ring + startIndex * 2, source + sourceOffset * 2, firstRegion * 2 * floatSize)
            if frames > firstRegion {
                memcpy(ring, source + (sourceOffset + firstRegion) * 2, (frames - firstRegion) * 2 * floatSize)
            }
        } else {
            memset(ring + startIndex * 2, 0, firstRegion * 2 * floatSize)
            if frames > firstRegion {
                memset(ring, 0, (frames - firstRegion) * 2 * floatSize)
            }
        }
        OSMemoryBarrier()
        _writeFrames = writeFrames &+ Int64(frameCount)
    }

    // MARK: - Command consumption (RT)

    /// Seqlock read: generation, barrier, payload, barrier, generation again.
    /// A publish racing this read is skipped and picked up next callback.
    private func consumeCommand() {
        let generation = _cmdGeneration
        guard generation != _consumedGeneration else { return }
        OSMemoryBarrier()
        let positionFrames = _cmdPosFrames
        let kind = _cmdKind
        OSMemoryBarrier()
        guard _cmdGeneration == generation else { return }
        _consumedGeneration = generation

        if kind == 1 {  // LIVE
            guard _pinnedToLive == 0 else { return }
            _shadowAbsQ = _readAbsQ
            _shadowRingQ = _readRingQ
            beginFade(.toLive, totalFrames: liveFadeFrames)
            return
        }

        // Seek: clamp the target into the valid window (§2.3).
        let writeFrames = _writeFrames
        let trailingFrames = max(0, writeFrames - Int64(capacityFrames) + Int64(marginFrames))
        let leadingFrames = max(0, writeFrames - 4)
        let targetQ = min(max(positionFrames, trailingFrames), leadingFrames) << Self.qShift
        _seeksConsumed &+= 1
        if _pinnedToLive != 0 {
            _pinnedToLive = 0
            // Seed the smoothed rate: there is no audible rate to ramp from,
            // and seeding keeps post-seek stepping exact (§7.2/§7.3).
            _currentRate = Float(bitPattern: _targetRateBits)
            setPrimary(targetQ)
            beginFade(.fromLive, totalFrames: seekFadeFrames)
        } else {
            _shadowAbsQ = _readAbsQ
            _shadowRingQ = _readRingQ
            setPrimary(targetQ)
            beginFade(.ringToRing, totalFrames: seekFadeFrames)
        }
    }

    @inline(__always)
    private func beginFade(_ kind: FadeKind, totalFrames: Int) {
        _fadeKind = kind.rawValue
        _fadeDone = 0
        _fadeTotal = Int32(max(1, totalFrames))
    }

    // MARK: - Transport render (RT)

    private func renderTransport(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let floatSize = MemoryLayout<Float>.size
        let writeFrames = _writeFrames
        // Empty tape: nothing the kernel can read yet — hold silence.
        guard writeFrames >= 8 else {
            memset(buffer, 0, frameCount * 2 * floatSize)
            finishOutput(buffer, frameCount: frameCount)
            return
        }
        let trailingFrames = max(0, writeFrames - Int64(capacityFrames) + Int64(marginFrames))
        let leadingFrames = writeFrames - 4
        let trailingQ = trailingFrames << Self.qShift
        let leadingQ = leadingFrames << Self.qShift

        var current = _currentRate
        let target = Float(bitPattern: _targetRateBits)
        let coeff = Float(bitPattern: _rateRampCoeffBits)

        // Stopped (post-snap): silence output; the window may drag the
        // position forward at the horizon (E18).
        if current == 0, target == 0, _fadeKind == FadeKind.none.rawValue {
            if _readAbsQ < trailingQ {
                if _atHorizon == 0 { _clampEventCount &+= 1 }
                _atHorizon = 1
                setPrimary(trailingQ)
            }
            memset(buffer, 0, frameCount * 2 * floatSize)
            finishOutput(buffer, frameCount: frameCount)
            return
        }

        // E18 horizon zone (skip-free — see header): inside the guard above
        // the trailing edge, a slower-than-live rate is forced to effective
        // 1.0 so the gap holds constant and no frames are ever skipped.
        let guardQ = Int64(horizonGuardFrames) << Self.qShift
        let forcedOneX = _fadeKind == FadeKind.none.rawValue
            && current < 1.0
            && _readAbsQ - trailingQ - guardQ <= 0
        if forcedOneX {
            if _atHorizon == 0 { _clampEventCount &+= 1 }
            _atHorizon = 1
        } else {
            _atHorizon = 0
        }

        // Loop region: read end-first (matching the publish order), clamp
        // into the window; a squeezed region degrades honestly (§2.5).
        let loopEndFrames = _loopEndFrames
        OSMemoryBarrier()
        let loopStartFrames = _loopStartFrames
        var loopActive = false
        var loopStartQ: Int64 = 0
        var loopEndQ: Int64 = 0
        var loopLenQ: Int64 = 0
        if loopEndFrames > 0 {
            let start = max(loopStartFrames, trailingFrames)
            let end = min(loopEndFrames, leadingFrames)
            if end - start >= Int64(max(2 * loopFadeFrames, 16)) {
                loopActive = true
                loopStartQ = start << Self.qShift
                loopEndQ = end << Self.qShift
                loopLenQ = loopEndQ - loopStartQ
                _loopDegraded = 0
            } else {
                _loopDegraded = 1
            }
        } else {
            _loopDegraded = 0
        }

        // Q2 auto-pin: fast-forward reaching the window's leading edge
        // returns to live through the same jump primitive. Never while a loop
        // is active — the loop wrap keeps the position bounded.
        if _fadeKind == FadeKind.none.rawValue, !loopActive, current > 1.0 {
            let stepNow = Int64((Double(current) * 16_777_216.0).rounded())
            if _readAbsQ &+ Int64(frameCount) &* stepNow > leadingQ {
                _shadowAbsQ = _readAbsQ
                _shadowRingQ = _readRingQ
                beginFade(.toLive, totalFrames: liveFadeFrames)
            }
        }

        let halfPi = Float.pi / 2
        let inverseKnee = 1.0 / Self.stopFadeKnee
        var frame = 0
        frameLoop: while frame < frameCount {
            // One-pole rate ramp with snap; the effective rate may be forced.
            if current != target {
                current += coeff * (target - current)
                if abs(current - target) < Self.rateSnapEpsilon { current = target }
            }
            let stepQ: Int64
            let effectiveRate: Float
            if forcedOneX {
                stepQ = Self.oneQ
                effectiveRate = 1.0
            } else {
                stepQ = Int64((Double(current) * 16_777_216.0).rounded())
                effectiveRate = current
            }
            // Stop-fade: gain dies with the effective rate below the knee.
            let gain = min(1.0, abs(effectiveRate) * inverseKnee)

            // Loop wrap through the jump primitive, both directions.
            if loopActive, _fadeKind == FadeKind.none.rawValue {
                if stepQ > 0, _readAbsQ >= loopEndQ {
                    _shadowAbsQ = _readAbsQ
                    _shadowRingQ = _readRingQ
                    var overshoot = _readAbsQ - loopEndQ
                    if overshoot >= loopLenQ { overshoot %= loopLenQ }
                    setPrimary(loopStartQ &+ overshoot)
                    beginFade(.ringToRing, totalFrames: loopFadeFrames)
                } else if stepQ < 0, _readAbsQ <= loopStartQ {
                    _shadowAbsQ = _readAbsQ
                    _shadowRingQ = _readRingQ
                    var undershoot = loopStartQ - _readAbsQ
                    if undershoot >= loopLenQ { undershoot %= loopLenQ }
                    setPrimary(loopEndQ &- undershoot)
                    beginFade(.ringToRing, totalFrames: loopFadeFrames)
                }
            }

            var outL: Float
            var outR: Float
            let kind = _fadeKind
            if kind == FadeKind.none.rawValue {
                (outL, outR) = interpolatedSample(ringQ: _readRingQ, gain: gain)
                advancePrimary(by: stepQ, trailingQ: trailingQ, leadingQ: leadingQ)
            } else {
                // Equal-power blend; the final fade frame (done+1 == total)
                // lands on the pure fading-in side.
                let theta = (Float(_fadeDone + 1) / Float(_fadeTotal)) * halfPi
                let outGain = cosf(theta)
                let inGain = sinf(theta)
                let fadeInL: Float
                let fadeInR: Float
                let fadeOutL: Float
                let fadeOutR: Float
                if kind == FadeKind.ringToRing.rawValue {
                    (fadeInL, fadeInR) = interpolatedSample(ringQ: _readRingQ, gain: gain)
                    (fadeOutL, fadeOutR) = interpolatedSample(ringQ: _shadowRingQ, gain: gain)
                    advancePrimary(by: stepQ, trailingQ: trailingQ, leadingQ: leadingQ)
                    advanceShadow(by: stepQ, trailingQ: trailingQ, leadingQ: leadingQ)
                } else if kind == FadeKind.fromLive.rawValue {
                    (fadeInL, fadeInR) = interpolatedSample(ringQ: _readRingQ, gain: gain)
                    fadeOutL = buffer[frame * 2]
                    fadeOutR = buffer[frame * 2 + 1]
                    advancePrimary(by: stepQ, trailingQ: trailingQ, leadingQ: leadingQ)
                } else {  // toLive: the live side is never attenuated.
                    fadeInL = buffer[frame * 2]
                    fadeInR = buffer[frame * 2 + 1]
                    (fadeOutL, fadeOutR) = interpolatedSample(ringQ: _shadowRingQ, gain: gain)
                    advanceShadow(by: stepQ, trailingQ: trailingQ, leadingQ: leadingQ)
                }
                outL = outGain * fadeOutL + inGain * fadeInL
                outR = outGain * fadeOutR + inGain * fadeInR
                _fadeDone &+= 1
                if _fadeDone >= _fadeTotal {
                    _fadeKind = FadeKind.none.rawValue
                    if kind == FadeKind.toLive.rawValue {
                        // Pin: the rest of the buffer is already live audio —
                        // leave it untouched (bit-exact hand-off, see header).
                        buffer[frame * 2] = outL
                        buffer[frame * 2 + 1] = outR
                        _pinnedToLive = 1
                        frame += 1
                        break frameLoop
                    }
                }
            }
            buffer[frame * 2] = outL
            buffer[frame * 2 + 1] = outR
            frame += 1
        }
        _currentRate = current
        finishOutput(buffer, frameCount: frameCount)
    }

    // MARK: - Read head (RT)

    /// Catmull-Rom in Horner form (c0 = p1): frac == 0 reproduces the stored
    /// sample bit-exactly and short-circuits to a direct read.
    @inline(__always)
    private func interpolatedSample(ringQ: Int64, gain: Float) -> (Float, Float) {
        let index = Int(ringQ >> Self.qShift)
        let fracBits = ringQ & Self.fracMask
        if fracBits == 0 {
            return (ring[index * 2] * gain, ring[index * 2 + 1] * gain)
        }
        let t = Float(fracBits) * Float(1.0 / 16_777_216.0)
        var index0 = index - 1
        if index0 < 0 { index0 += capacityFrames }
        var index2 = index + 1
        if index2 >= capacityFrames { index2 -= capacityFrames }
        var index3 = index + 2
        if index3 >= capacityFrames { index3 -= capacityFrames }
        let left = catmullRom(
            ring[index0 * 2], ring[index * 2], ring[index2 * 2], ring[index3 * 2], t
        )
        let right = catmullRom(
            ring[index0 * 2 + 1], ring[index * 2 + 1], ring[index2 * 2 + 1], ring[index3 * 2 + 1], t
        )
        return (left * gain, right * gain)
    }

    @inline(__always)
    private func catmullRom(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let c1 = 0.5 * (p2 - p0)
        let c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
        let c3 = 1.5 * (p1 - p2) + 0.5 * (p3 - p0)
        return p1 + t * (c1 + t * (c2 + t * c3))
    }

    /// Advance with a per-frame safety clamp. The clamp is a last resort for
    /// extreme rates crossing an edge mid-callback (e.g. −4× into the
    /// horizon); the E18 zone and Q2 auto-pin keep the common paths off it.
    @inline(__always)
    private func advancePrimary(by stepQ: Int64, trailingQ: Int64, leadingQ: Int64) {
        let advanced = _readAbsQ &+ stepQ
        if advanced > leadingQ {
            setPrimary(leadingQ)
        } else if advanced < trailingQ {
            setPrimary(trailingQ)
        } else {
            _readAbsQ = advanced
            var ringQ = _readRingQ &+ stepQ
            if ringQ >= capQ {
                ringQ -= capQ
            } else if ringQ < 0 {
                ringQ += capQ
            }
            _readRingQ = ringQ
        }
    }

    /// The dying side of a fade holds still rather than cross a window edge.
    @inline(__always)
    private func advanceShadow(by stepQ: Int64, trailingQ: Int64, leadingQ: Int64) {
        let advanced = _shadowAbsQ &+ stepQ
        guard advanced <= leadingQ, advanced >= trailingQ else { return }
        _shadowAbsQ = advanced
        var ringQ = _shadowRingQ &+ stepQ
        if ringQ >= capQ {
            ringQ -= capQ
        } else if ringQ < 0 {
            ringQ += capQ
        }
        _shadowRingQ = ringQ
    }

    /// Set the absolute read position (Q40.24, must be ≥ 0) and derive the
    /// ring-wrapped twin — the one modulo per jump/clamp.
    @inline(__always)
    private func setPrimary(_ absQ: Int64) {
        _readAbsQ = absQ
        let frames = absQ >> Self.qShift
        _readRingQ = ((frames % Int64(capacityFrames)) << Self.qShift) | (absQ & Self.fracMask)
    }

    // MARK: - Output bookkeeping (RT)

    @inline(__always)
    private func updatePeak(_ buffer: UnsafePointer<Float>, frameCount: Int) {
        var peak: Float = 0
        vDSP_maxmgv(buffer, 1, &peak, vDSP_Length(frameCount * 2))
        _lastOutputPeak = peak
    }

    @inline(__always)
    private func finishOutput(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        updatePeak(buffer, frameCount: frameCount)
        let mirrorFrames = min(frameCount, Self.mirrorCapacityFrames)
        memcpy(mirrorStore, buffer, mirrorFrames * 2 * MemoryLayout<Float>.size)
        _lastOutputFrames = mirrorFrames
    }
}
