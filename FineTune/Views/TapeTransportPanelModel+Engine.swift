// FineTune/Views/TapeTransportPanelModel+Engine.swift
import Foundation

// MARK: - Engine state → view state

extension TapeTransportPanelModel {

    /// How long the "Tape restarted" notice stays up after a rate change cleared
    /// the tape (E22), and how long the save button holds its tick. Both are
    /// view-side only: the transport records *when* it happened, this decides how
    /// long that is worth showing.
    static let clearedNoticeDuration: TimeInterval = 10
    static let exportDoneDuration: TimeInterval = 3

    /// Reads one app's transport into view state. **Pure**: it creates nothing
    /// and mutates nothing, so it is safe to call while `body` is evaluating.
    /// Every command in the model built from it goes the other way, through
    /// `editableTapeTransport(for:appName:)` inside a closure that runs after the
    /// render.
    ///
    /// `transport` is `nil` for an app whose tape has never been armed; the
    /// persisted `config` is then all there is to show. A transport with no ring
    /// yet (armed, still allocating, or waiting for a tap) reports an empty tape
    /// sitting at live, which is the truth.
    @MainActor
    init(config: TapeTransportConfig, transport: AppTapeTransport?, now: Date = Date()) {
        self.init()

        let config = transport?.config ?? config
        isEnabled = config.isEnabled
        ringMinutes = config.ringMinutes
        capacitySeconds = Double(config.ringMinutes * 60)
        preservePitch = config.preservePitch
        preservePitchAvailable = false  // T7 (keep pitch) is not built yet

        guard let transport else { return }
        rate = transport.rate
        isStopped = transport.isBraked
        if transport.isExporting {
            exportState = .exporting
        } else if let completed = transport.lastExportCompletedAt,
                  now.timeIntervalSince(completed) < Self.exportDoneDuration {
            exportState = .done(until: completed.addingTimeInterval(Self.exportDoneDuration))
        }
        if let cleared = transport.lastClearedAt, now.timeIntervalSince(cleared) < Self.clearedNoticeDuration {
            clearedNoticeActive = true
        }

        guard let ring = transport.transport else { return }
        let diagnostics = ring.diagnosticsSnapshot()
        // What the user can actually reach: the ring minus the writer's 1 s
        // margin. Reporting raw capacity would let the scrub bar offer audio the
        // RT thread would silently clamp away.
        let reachableFrames = min(diagnostics.writeFrames, Int64(ring.capacityFrames - ring.marginFrames))
        recordedSeconds = Double(max(0, reachableFrames)) / ring.sampleRate
        secondsBehindLive = Double(diagnostics.lagFrames) / ring.sampleRate
        isLive = diagnostics.isPinnedToLive
        atHorizon = diagnostics.isAtHorizon
        loop = transport.loopSecondsBehindLive()
    }
}

// MARK: - Command wiring

extension MenuBarPopupView {

    /// The tape strip's and Tape panel's view state for one app, with every
    /// callback wired to a real transport command (spec §3, §6, §7).
    ///
    /// **Propagation**: unlike the AU chain, most of what this shows is written
    /// by the RT thread (position, live/behind, horizon), which no `@Observable`
    /// can announce. `AppRowWithLevelPolling` therefore rebuilds this model on
    /// the VU meter's existing 30 Hz tick — nothing new polls, and nothing polls
    /// from the render path.
    ///
    /// **Read-only on purpose**: `transport(for:)` looks up, never creates.
    /// Creating a transport mutates the manager, which must not happen during
    /// view evaluation, so every mutation below sits inside a closure.
    func tapeModel(for persistenceID: String, appName: String) -> TapeTransportPanelModel {
        let engine = audioEngine
        let manager = engine.tapeTransportManager
        let config = manager.config(for: persistenceID)
        var model = TapeTransportPanelModel(config: config, transport: manager.transport(for: persistenceID))

        // Runs after the render, never during it — this is the call that can
        // create a transport and bind it to the live tap.
        func edit() -> AppTapeTransport {
            engine.editableTapeTransport(for: persistenceID, appName: appName)
        }

        model.onEnable = { minutes in
            let transport = edit()
            transport.setRingMinutes(minutes)
            transport.setEnabled(true)
        }
        model.onDisable = { edit().setEnabled(false) }
        model.onRingLengthChange = { edit().setRingMinutes($0) }
        model.onScrub = { edit().scrub(toSecondsBehindLive: $0) }
        model.onScrubEnd = { edit().endScrub(snapToLiveWithin: TapeTransportMath.snapToLiveThreshold) }
        model.onLive = { edit().goLive() }
        model.onStopToggle = {
            let transport = edit()
            transport.setBraked(!transport.isBraked)
        }
        model.onSpeedChange = { edit().setRate($0) }
        model.onLoopGrab = { edit().grabLoop(lastSeconds: TapeTransportMath.loopGrabSeconds) }
        model.onLoopClear = { edit().clearLoop() }
        model.onLoopEdgeDrag = { edge, seconds in
            edit().setLoopEdge(
                isStart: edge == .start,
                secondsBehindLive: seconds,
                minimumLength: TapeTransportMath.minimumLoopLength
            )
        }
        // The edge is pushed on every drag change, so the release has nothing
        // left to commit.
        model.onLoopEdgeDragEnd = {}
        // Length is read from the transport at click time, not captured from the
        // model-build snapshot: the two are up to one 30 Hz tick apart (T10/N5).
        model.onExport = {
            let transport = edit()
            _ = transport.export(lastMinutes: Double(transport.config.ringMinutes))
        }
        model.onPreservePitchToggle = { edit().setPreservePitch($0) }
        return model
    }
}
