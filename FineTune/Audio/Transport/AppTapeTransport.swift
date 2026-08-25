// FineTune/Audio/Transport/AppTapeTransport.swift
import Foundation
import os

// MARK: - Threading Model
//
// AppTapeTransport owns the `TapeTransportRT` object for ONE app and runs its
// lifecycle (spec §2.6). Like AppAUChain it is never on the RT thread at all;
// unlike AppAUChain what it owns is long-lived MUTABLE RT state, so the split
// between lifecycle and control is the load-bearing distinction here:
//
// 1. **MainActor** — the whole class. Enable / disable / resize / rate rebuild /
//    attach / export kickoff. These are the ONLY events that swap the tap's
//    published pointer.
// 2. **Utility queue** — ring allocation + zero-fill (up to ~346 MB, E23), the
//    release grace, and the free. Reached via `withCheckedContinuation`, never
//    `.sync` — the main thread never blocks on this queue.
// 3. **HAL I/O thread** — inside `TapeTransportRT`, not here.
//
// **Control changes never come through this class**: rate, seek, LIVE and loop
// are aligned atomic stores straight onto the published `TapeTransportRT`
// (§2.2). A mode change must not cost a 115 MB reallocation, so it is not a
// lifecycle event and does not touch anything below.
//
// **Release ordering (E15 + E23) — the most dangerous rule in this file.**
// Publishing `nil` to the tap does not make the ring unreachable: the RT thread
// may still be inside `writeAndRender` for up to the 0.5 s grace the tap's
// deferred release is built around. So every teardown is, in order:
//
//     publish nil  →  wait the grace (utility queue)  →  drop the last reference
//
// Freeing early is a use-after-free on the audio thread that will not crash
// until it ships. `scheduleFree` holds those three steps adjacent on purpose.
//
// **The export refcount (§2.6)** falls out of that ordering: an in-flight export
// holds its own strong reference to the same object, so `disable()` drops only
// OURS and the ring is freed when the exporter lets go — not before.

/// What an `AppTapeTransport` needs from the thing that renders it.
/// `ProcessTapController` conforms (T5); tests use a fake. Deliberately one
/// method: the transport is independent of the AU chain layer (§2.1) — an app
/// with a ring and no chain works, and vice versa.
@MainActor
protocol TapeTransportHosting: AnyObject {
    /// Publishes the ring to the tap by atomic pointer swap (the `setAUChain`
    /// idiom); `nil` drops it. The tap never OWNS the object — taps are
    /// disposable, rings are not.
    func setTransport(_ transport: TapeTransportRT?)
}

/// @MainActor lifecycle owner of one app's tape (spec §2.6).
@Observable
@MainActor
final class AppTapeTransport {

    enum State: Equatable {
        case disabled
        /// Ring is being allocated + zeroed on the utility queue (E23).
        case allocating
        case ready
    }

    /// E15/E23 release grace. After the tap's pointer is dropped the RT thread
    /// may still be inside `writeAndRender`; 0.5 s outlives any in-flight HAL
    /// callback. Same value, same reason, as the AU chain's dealloc grace.
    nonisolated static let releaseGracePeriod: TimeInterval = 0.5

    let identifier: String
    /// Used for the export filename; kept current by the manager.
    var appName: String

    private(set) var config: TapeTransportConfig
    private(set) var state: State = .disabled
    /// Rate the ring records at. `nil` until a tap attaches.
    private(set) var sampleRate: Double?
    /// The published object, for UI polling and for the command setters (rate,
    /// seek, LIVE, loop) which callers invoke directly — see the header.
    private(set) var transport: TapeTransportRT?

    // MARK: - Transport state the UI reads back (not persisted)
    //
    // The RT object takes commands but hands nothing back except diagnostics, so
    // "what did the user ask for" lives here: it survives the tap churn the ring
    // survives, and it is re-applied to a ring rebuilt by a rate change. None of
    // it is persisted — §3-I persists intent (armed, length, keep-pitch) only, so
    // a fresh tape always starts at normal speed, unbraked, with no loop.

    /// Requested tape speed; 1.0 = normal. Live passthrough ignores it, which is
    /// why setting it while live is silent until the next rewind.
    private(set) var rate: Double = 1.0
    /// Tape brake engaged (§2.5): the effective rate is ramping to, or sitting
    /// at, zero. Play releases it back to `rate`.
    private(set) var isBraked = false
    /// Loop region in ABSOLUTE write-clock frames, so it stays put on the tape
    /// while live runs away from it. `nil` = no loop.
    private(set) var loopFrames: (start: Int64, end: Int64)?
    /// Where the in-progress scrub last asked to be, so the release can decide
    /// to snap to live without racing the RT thread's command consumption (§6).
    private(set) var pendingScrubSecondsBehind: Double?
    /// When a device rate change last discarded the tape (E22) — drives the
    /// view's "Tape restarted" notice.
    private(set) var lastClearedAt: Date?
    private(set) var isExporting = false
    /// When a save last actually wrote a file. A failed save leaves this alone.
    private(set) var lastExportCompletedAt: Date?

    /// Manager hook: config changed and should be persisted (§3-I).
    var onPersist: @MainActor (TapeTransportConfig) -> Void = { _ in }

    /// T6 seam. The exporter copies the window out on its own queue while this
    /// call is awaited; the awaiting Task holds a strong reference to the
    /// transport for the whole duration, which IS the export refcount (§2.6).
    /// Returns whether a file actually landed, so the UI's tick is a fact
    /// rather than "the attempt finished".
    var onExport: (@MainActor (
        _ transport: TapeTransportRT,
        _ endFrame: Int64,
        _ frameCount: Int,
        _ appName: String
    ) async -> Bool)?

    private weak var host: TapeTransportHosting?
    private let queue: DispatchQueue
    private let makeRT: @Sendable (_ rate: Double, _ capacityFrames: Int) -> TapeTransportRT
    private let graceWait: @Sendable () -> Void
    /// Bumped by every disable and rate change, so an allocation still in flight
    /// can tell it is stale and discard its ring instead of publishing it (E23).
    private var generation: UInt64 = 0
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "TapeTransport")

    init(
        identifier: String,
        appName: String,
        config: TapeTransportConfig,
        makeRT: @escaping @Sendable (Double, Int) -> TapeTransportRT = {
            TapeTransportRT(sampleRate: $0, capacityFrames: $1)
        },
        graceWait: @escaping @Sendable () -> Void = {
            Thread.sleep(forTimeInterval: AppTapeTransport.releaseGracePeriod)
        }
    ) {
        self.identifier = identifier
        self.appName = appName
        self.config = config
        self.makeRT = makeRT
        self.graceWait = graceWait
        self.queue = DispatchQueue(label: "TapeTransport.\(identifier)", qos: .utility)
    }

    /// Exact ring length, never padded (§2.3): `minutes × 60 × rate`.
    nonisolated static func capacityFrames(rate: Double, minutes: Int) -> Int {
        Int((rate * 60.0 * Double(minutes)).rounded())
    }

    // MARK: - Host wiring (called by TapeTransportManager)

    /// Binds the transport to a tap. Taps are disposable and get recreated by
    /// device switches, health recovery and sleep/wake — a re-attach at the SAME
    /// rate republishes the same object, so position, tape content and mode all
    /// survive the churn. That is the whole reason the ring is owned out here.
    func attach(to host: TapeTransportHosting, sampleRate rate: Double) {
        self.host = host
        guard config.isEnabled else {
            // Remember the tap's rate even while the tape is off: arming it from
            // the panel must allocate straight away, not wait for tap churn.
            sampleRate = rate
            return
        }
        if let current = sampleRate, current != rate {
            // A tap came back on a different-rate device (E22 self-heal).
            rateChanged(to: rate)
            return
        }
        sampleRate = rate
        if let transport, state == .ready {
            host.setTransport(transport)
            return
        }
        // `.allocating` falls through to the guard in `enable`: the in-flight
        // build publishes to whichever host is current when it lands (E32).
        enable(rate: rate)
    }

    /// Allocates the ring off-main and publishes it (§2.6). No-op unless
    /// currently torn down — a second call while allocating is not a second ring.
    func enable(rate: Double) {
        sampleRate = rate
        guard state == .disabled else { return }
        generation &+= 1
        let generationAtStart = generation
        state = .allocating
        let capacity = Self.capacityFrames(rate: rate, minutes: config.ringMinutes)
        let build = makeRT
        let allocationQueue = queue
        track {
            // E23: alloc + zero of up to ~346 MB. On MainActor this stalls the popup.
            // `var` so the orphan path can hand sole ownership to the box below
            // and let the free happen off-main too.
            var built: TapeTransportRT? = await withCheckedContinuation { continuation in
                allocationQueue.async { continuation.resume(returning: build(rate, capacity)) }
            }
            guard self.isCurrent(generationAtStart) else {
                // A disable or rate change landed while we were allocating.
                // Publishing now would hand the tap a ring nobody owns; free the
                // orphan instead. No grace is owed — it was never published, so
                // no RT thread can be inside it.
                self.logger.debug("Discarding stale tape allocation for \(self.identifier, privacy: .public)")
                let box = Box(built)
                built = nil
                await self.freeOffMain(box)
                return
            }
            self.transport = built
            self.state = .ready
            // A ring rebuilt under the user (device switch, resize) inherits the
            // speed they set; the tape itself is gone, their settings are not.
            built?.setTargetRate(Float(self.rate))
            self.host?.setTransport(built)
        }
    }

    /// Drops the ring: publish `nil`, wait out the grace, then free (E15).
    /// Does NOT change `config` — this is lifecycle, not user intent.
    func disable() {
        generation &+= 1
        state = .disabled
        let released = transport
        transport = nil
        // The loop is absolute frames on a write clock that is about to restart
        // from zero, and a brake on a ring nobody is playing is meaningless.
        // Both would otherwise be re-applied to the next ring as garbage.
        loopFrames = nil
        pendingScrubSecondsBehind = nil
        isBraked = false
        // 1. The tap must stop seeing the ring before anything frees it.
        host?.setTransport(nil)
        guard let released else { return }
        scheduleFree(released)
    }

    /// Device switch / A2DP↔SCO re-rate (§3-Q6, E22). The recorded frames are in
    /// old-rate time and there is deliberately no resample path, so the tape is
    /// discarded and the transport comes back with an empty ring, pinned to live.
    func rateChanged(to newRate: Double) {
        guard sampleRate != newRate else { return }
        disable()
        sampleRate = newRate
        guard config.isEnabled else { return }
        logger.debug("Tape cleared for \(self.identifier, privacy: .public) — device rate changed")
        // Stamped only when a tape was actually armed: the notice tells the user
        // their recording is gone, and there is nothing to say if there was none.
        lastClearedAt = Date()
        enable(rate: newRate)
    }

    /// The app left the list (E29): free the ring and forget the tap. Rebuilt
    /// from config on demand.
    func release() {
        disable()
        host = nil
    }

    // MARK: - Config (persisted user intent, §3-I)

    func setEnabled(_ enabled: Bool) {
        guard config.isEnabled != enabled else { return }
        config.isEnabled = enabled
        onPersist(config)
        guard enabled else {
            disable()
            return
        }
        // No rate yet means no tap yet: the next attach arms it.
        guard let sampleRate else { return }
        enable(rate: sampleRate)
    }

    /// Resize is disable + enable — the tape clears, which the UI copy states (§3-Q5).
    func setRingMinutes(_ minutes: Int) {
        let updated = TapeTransportConfig(
            isEnabled: config.isEnabled,
            ringMinutes: minutes,
            preservePitch: config.preservePitch
        )
        guard updated.ringMinutes != config.ringMinutes else { return }
        config = updated
        onPersist(config)
        guard config.isEnabled, let sampleRate else { return }
        disable()
        enable(rate: sampleRate)
    }

    /// T7 preference. Stored and persisted only — nothing reads it until the
    /// speed-without-pitch path is built.
    func setPreservePitch(_ preservePitch: Bool) {
        guard config.preservePitch != preservePitch else { return }
        config.preservePitch = preservePitch
        onPersist(config)
    }

    // MARK: - Transport commands (the strip's buttons land here)
    //
    // Every one of these is an aligned atomic store onto the published ring, NOT
    // a lifecycle event (see the header): none of them reallocates, and all of
    // them no-op safely while the ring is absent or still allocating.

    func setRate(_ newRate: Double) {
        rate = newRate
        guard !isBraked else { return }  // play will apply it
        transport?.setTargetRate(Float(newRate))
    }

    /// Tape brake / play. Braking rides the 0.8 s brake ramp; play returns to the
    /// requested rate through the ordinary one.
    func setBraked(_ braked: Bool) {
        isBraked = braked
        if braked {
            transport?.setTargetRate(0, rampSeconds: TapeTransportRT.brakeRampSeconds)
        } else {
            transport?.setTargetRate(Float(rate))
        }
    }

    /// Scrub to a point behind live. The RT thread clamps the target into the
    /// valid window, so an over-long drag lands on the oldest audio rather than
    /// failing.
    func scrub(toSecondsBehindLive seconds: Double) {
        guard let transport else { return }
        let behind = max(0, seconds)
        pendingScrubSecondsBehind = behind
        transport.requestSeek(toFrame: max(0, transport.writtenFrames - Int64((behind * transport.sampleRate).rounded())))
    }

    /// Scrub release: a drag that ended within `threshold` of live returns to
    /// live rather than leaving the user a fraction of a second behind it (§6).
    func endScrub(snapToLiveWithin threshold: Double) {
        let pending = pendingScrubSecondsBehind
        pendingScrubSecondsBehind = nil
        guard let pending, pending < threshold else { return }
        goLive()
    }

    /// LIVE. Releases the brake too: a stopped tape that is back at live is
    /// playing, and must not keep reporting itself stopped.
    func goLive() {
        if isBraked { setBraked(false) }
        transport?.requestLive()
    }

    /// Loop the last `seconds` of tape and drop the read head at its start, so
    /// the button loops something audible instead of arming a region live
    /// passthrough never reaches.
    func grabLoop(lastSeconds: Double) {
        guard let transport else { return }
        let end = max(0, transport.writtenFrames - 4)
        let start = max(0, end - Int64((lastSeconds * transport.sampleRate).rounded()))
        guard end > start else { return }
        loopFrames = (start: start, end: end)
        transport.setLoop(startFrame: start, endFrame: end)
        transport.requestSeek(toFrame: start)
    }

    func clearLoop() {
        loopFrames = nil
        transport?.clearLoop()
    }

    /// Drags one loop handle. The minimum length is held by pushing the OTHER
    /// edge, never the one under the user's finger — matching what the scrub
    /// bar draws while the drag is in flight.
    func setLoopEdge(isStart: Bool, secondsBehindLive seconds: Double, minimumLength: Double) {
        guard let transport, let existing = loopFrames else { return }
        let written = transport.writtenFrames
        let minimum = max(Int64((minimumLength * transport.sampleRate).rounded()), 1)
        let frame = max(0, written - Int64((max(0, seconds) * transport.sampleRate).rounded()))
        var start = existing.start
        var end = existing.end
        if isStart {
            start = min(frame, max(0, written - minimum))
            end = max(end, start + minimum)
        } else {
            end = max(frame, minimum)
            start = max(0, min(start, end - minimum))
            end = max(end, start + minimum)
        }
        loopFrames = (start: start, end: end)
        transport.setLoop(startFrame: start, endFrame: end)
    }

    /// The loop region expressed as seconds behind live, for the scrub bar. It
    /// drifts leftward as live runs on, which is exactly what a real tape does.
    func loopSecondsBehindLive() -> (startBehind: Double, endBehind: Double)? {
        guard let loopFrames, let transport else { return nil }
        let written = transport.writtenFrames
        return (
            startBehind: max(0, Double(written - loopFrames.start) / transport.sampleRate),
            endBehind: max(0, Double(written - loopFrames.end) / transport.sampleRate)
        )
    }

    // MARK: - Retro-record (§3-Q5, the T6 seam)

    /// Snapshots the write position and hands the ring to the exporter. Returns
    /// false when there is nothing to export or no exporter wired.
    @discardableResult
    func export(lastMinutes: Double) -> Bool {
        guard state == .ready, let transport, let onExport else { return false }
        // One snapshot of the write clock; the exporter re-validates each chunk
        // against the still-advancing writer itself (E24).
        let endFrame = transport.writtenFrames
        // The reachable past is capacity minus the 1 s writer margin (§2.3).
        let reachable = transport.capacityFrames - transport.marginFrames
        let requested = Int((lastMinutes * 60.0 * transport.sampleRate).rounded())
        let frameCount = min(requested, min(reachable, Int(clamping: endFrame)))
        guard frameCount > 0 else { return false }
        let name = appName
        isExporting = true
        track {
            // `transport` is captured strongly for the whole call: this is the
            // export refcount (§2.6). A disable during the copy drops only the
            // reference this class holds; the ring survives until we let go.
            let wrote = await onExport(transport, endFrame, frameCount, name)
            self.isExporting = false
            if wrote { self.lastExportCompletedAt = Date() }
        }
        return true
    }

    // MARK: - Teardown plumbing (E15 + E23 ordering lives here)

    /// Waits out the render grace on the utility queue and only then drops the
    /// last reference this class holds. The caller MUST have published `nil`
    /// first — that publication is what starts the window being waited out.
    private func scheduleFree(_ released: TapeTransportRT) {
        let box = Box(released)
        let wait = graceWait
        track { await self.freeOffMain(box, waitingOut: wait) }
    }

    /// Drops the box's reference on the utility queue, optionally waiting out
    /// the render grace first. Freeing hundreds of MB stalls MainActor exactly
    /// as allocating them does, so neither end happens there.
    private func freeOffMain(_ box: Box, waitingOut wait: (@Sendable () -> Void)? = nil) async {
        let freeQueue = queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            freeQueue.async {
                // 2. E15: the RT thread may still be inside `writeAndRender` on
                //    the pointer the tap just dropped. Wait it out.
                wait?()
                // 3. Only now is the ring safe to free. If an export still holds
                //    this object, ITS reference is the last one and the free
                //    happens when the exporter finishes (§2.6).
                box.value = nil
                continuation.resume()
            }
        }
    }

    /// Carries sole ownership onto the queue, so the free happens at a
    /// determinate point inside the block — after the grace — rather than
    /// whenever the block itself is deallocated.
    private final class Box: @unchecked Sendable {
        var value: TapeTransportRT?
        init(_ value: TapeTransportRT?) { self.value = value }
    }

    // MARK: - Task tracking

    private func track(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        pendingTasks[key] = Task { @MainActor in
            await body()
            self.pendingTasks.removeValue(forKey: key)
        }
    }

    /// Awaits every in-flight lifecycle Task, including ones they spawn (a rate
    /// change queues a free and an allocation). Tests use it instead of polling.
    func waitForPendingWork() async {
        while !pendingTasks.isEmpty {
            for task in Array(pendingTasks.values) { await task.value }
        }
    }

    private func isCurrent(_ generationAtStart: UInt64) -> Bool {
        generation == generationAtStart
    }
}
