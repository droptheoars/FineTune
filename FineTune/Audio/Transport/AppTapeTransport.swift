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

    /// Manager hook: config changed and should be persisted (§3-I).
    var onPersist: @MainActor (TapeTransportConfig) -> Void = { _ in }

    /// T6 seam. The exporter copies the window out on its own queue while this
    /// call is awaited; the awaiting Task holds a strong reference to the
    /// transport for the whole duration, which IS the export refcount (§2.6).
    var onExport: (@MainActor (
        _ transport: TapeTransportRT,
        _ endFrame: Int64,
        _ frameCount: Int,
        _ appName: String
    ) async -> Void)?

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
        track {
            // `transport` is captured strongly for the whole call: this is the
            // export refcount (§2.6). A disable during the copy drops only the
            // reference this class holds; the ring survives until we let go.
            await onExport(transport, endFrame, frameCount, name)
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
