// FineTune/Audio/Transport/TapeExporter.swift
import AVFoundation
import AppKit
import Foundation
import os

// MARK: - Threading Model
//
// TapeExporter is the retro-record half of the transport (spec §3-Q5, I3): the
// user hits save because they want to keep something that ALREADY happened, so
// the one outcome that must be impossible is a corrupt or torn file presented
// as a finished one.
//
// 1. **MainActor** — the class. Single-flight guard, filename, Finder reveal.
//    Nothing here touches the ring.
// 2. **Utility queue** — every byte of the copy and every byte of file IO,
//    reached via `withCheckedContinuation` (the AppTapeTransport idiom); the
//    main thread never blocks on it.
// 3. **HAL I/O thread** — never. `TapeTransportRT.copyRingWindow` is lock-free
//    and cannot make the writer wait; the exporter is invisible to the RT
//    thread by construction, which is why "export while playing" is safe.
//
// **The writer race (E24) — the rule this file exists to get right.** The ring
// keeps overwriting itself while we copy. Each chunk is copied and then
// re-validated against the live, still-advancing overwrite point; a chunk the
// writer reached during the copy is torn and is never written to disk.
//
// A torn chunk cannot simply be skipped: the writer is monotonic, so losing
// chunk k means chunks 0…k are gone too, and the bytes already on disk are the
// head of a file that no longer has a coherent start. So a lost head restarts
// the attempt from the ring's *current* oldest frame — which is further
// forward, hence the spec's "at worst a few seconds shorter at its oldest end,
// never torn". Restarts are bounded (`maxAttempts`): the copy outruns the
// writer by ~250× on any working disk, so an attempt that keeps losing the head
// is a real IO problem and fails honestly rather than looping.
//
// **Nothing partial is ever presented as finished.** Bytes go to a hidden
// sibling of the destination and are moved into place only after the last chunk
// is written; every failure path — disk full, unwritable destination, lost
// window — deletes it.
//
// **What the file contains (E25)**: the post-fader, post-EQ signal. No plugin
// chain, no headphone correction, no loudness or limiter. Deliberate, and
// already stated in the export UI copy — do not try to render effects into it.

/// Retro-record: writes the last N frames of one app's tape to a WAV file
/// (spec §3-Q5). Assign `onExportHandler` to `AppTapeTransport.onExport`.
@MainActor
final class TapeExporter {

    enum Failure: Error, Equatable {
        /// One export at a time — the disk is the shared resource.
        case alreadyRunning
        /// Nothing recorded, or a zero-length window asked for.
        case emptyWindow
        case destinationNotWritable(String)
        case insufficientSpace(needed: Int64, available: Int64)
        /// The writer overwrote the window faster than it could be copied.
        case windowLost
        case writeFailed(String)
    }

    /// `~/Music/FineTune` (§3-Q5).
    nonisolated static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Music", isDirectory: true)
        .appendingPathComponent("FineTune", isDirectory: true)

    /// Head-loss restart budget — see the header.
    nonisolated static let maxAttempts = 3

    /// ~1.4 s at 48 kHz; 512 KB of interleaved Float32 per copy+write cycle.
    nonisolated static let defaultChunkFrames = 65_536

    var destinationDirectory: URL = TapeExporter.defaultDirectory
    var chunkFrames: Int = TapeExporter.defaultChunkFrames
    var revealInFinder: @MainActor (URL) -> Void = {
        NSWorkspace.shared.activateFileViewerSelecting([$0])
    }
    /// Free space on the destination volume. Injected in tests so the
    /// disk-full refusal can be exercised without filling a disk.
    var availableCapacity: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
    /// The one ring read, injected so the writer race is testable by ordering
    /// rather than by timing (house convention).
    var copyChunk: @Sendable (TapeTransportRT, Int64, Int, UnsafeMutablePointer<Float>) -> Bool = {
        $0.copyRingWindow(from: $1, frameCount: $2, into: $3)
    }

    private var isExporting = false
    private let queue = DispatchQueue(label: "TapeExporter", qos: .utility)
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "TapeExport")

    /// The `AppTapeTransport.onExport` seam: same call, failures logged instead
    /// of thrown (the seam is `async -> Void`).
    var onExportHandler: @MainActor (TapeTransportRT, Int64, Int, String) async -> Void {
        { [weak self] transport, endFrame, frameCount, appName in
            guard let self else { return }
            _ = try? await self.export(
                transport, endFrame: endFrame, frameCount: frameCount, appName: appName
            )
        }
    }

    /// Writes frames `[endFrame − frameCount, endFrame)` of `transport`'s ring
    /// to a WAV file and reveals it in Finder. `frameCount` is clamped to what
    /// the ring still holds, so asking for more than exists yields what exists.
    @discardableResult
    func export(
        _ transport: TapeTransportRT,
        endFrame: Int64,
        frameCount: Int,
        appName: String
    ) async throws -> URL {
        guard !isExporting else {
            logger.error("Tape export refused: another export is already running")
            throw Failure.alreadyRunning
        }
        guard frameCount > 0, endFrame > 0 else {
            logger.error("Tape export refused: nothing recorded yet")
            throw Failure.emptyWindow
        }
        isExporting = true
        defer { isExporting = false }

        let directory = destinationDirectory
        let destination = directory.appendingPathComponent(
            Self.fileName(appName: appName, date: Date())
        )
        let chunk = max(1, chunkFrames)
        let capacity = availableCapacity
        let copy = copyChunk
        let log = logger

        let result: Result<URL, Failure> = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.write(
                    transport: transport,
                    endFrame: endFrame,
                    requestedFrames: frameCount,
                    to: destination,
                    in: directory,
                    chunkFrames: chunk,
                    availableCapacity: capacity,
                    copyChunk: copy,
                    logger: log
                ))
            }
        }

        switch result {
        case .success(let url):
            logger.notice("Tape exported to \(url.path, privacy: .public)")
            revealInFinder(url)
            return url
        case .failure(let failure):
            logger.error("Tape export failed: \(String(describing: failure), privacy: .public)")
            throw failure
        }
    }

    // MARK: - Utility queue

    /// The whole copy + write, off MainActor. Returns rather than throws so the
    /// continuation stays non-throwing.
    private nonisolated static func write(
        transport: TapeTransportRT,
        endFrame: Int64,
        requestedFrames: Int,
        to destination: URL,
        in directory: URL,
        chunkFrames: Int,
        availableCapacity: @Sendable (URL) -> Int64?,
        copyChunk: @Sendable (TapeTransportRT, Int64, Int, UnsafeMutablePointer<Float>) -> Bool,
        logger: Logger
    ) -> Result<URL, Failure> {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.destinationNotWritable(error.localizedDescription))
        }

        // Refuse up front rather than discovering it 300 MB in. WAV header is
        // negligible next to the body; 4 KB covers it.
        let needed = Int64(requestedFrames) * 8 + 4096
        if let available = availableCapacity(directory), available < needed {
            return .failure(.insufficientSpace(needed: needed, available: available))
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: transport.sampleRate,
            channels: 2,
            interleaved: true
        ) else {
            return .failure(.writeFailed("unsupported device rate \(transport.sampleRate)"))
        }
        // Float32 WAV at device rate (§3-Q5): bit-exact, universal, no encoder.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: transport.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // Hidden sibling, same directory (same volume, so the move is a rename)
        // and same .wav extension, which is what AVAudioFile reads to pick the
        // container. Nothing partial ever wears the destination's name.
        let partial = directory.appendingPathComponent("." + destination.lastPathComponent)

        /// One full pass. Scoped so `AVAudioFile` deinits — and therefore
        /// flushes and closes — before the file is moved or deleted.
        func attempt(from startFrame: Int64) -> Failure? {
            do {
                let file = try AVAudioFile(
                    forWriting: partial,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: true
                )
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)
                ), let scratch = buffer.floatChannelData?[0] else {
                    return .writeFailed("could not allocate the export buffer")
                }
                var cursor = startFrame
                while cursor < endFrame {
                    let frames = Int(min(Int64(chunkFrames), endFrame - cursor))
                    guard copyChunk(transport, cursor, frames, scratch) else { return .windowLost }
                    buffer.frameLength = AVAudioFrameCount(frames)
                    try file.write(from: buffer)
                    cursor += Int64(frames)
                }
                return nil
            } catch {
                // Disk full mid-write lands here, as does every other IO fault.
                return .writeFailed(error.localizedDescription)
            }
        }

        var lastFailure: Failure = .windowLost
        for pass in 1...maxAttempts {
            try? manager.removeItem(at: partial)
            // Re-derived every attempt: the writer has advanced, so a restart
            // simply begins further forward and the file is shorter (E24).
            let oldest = max(
                0,
                transport.writtenFrames
                    - Int64(transport.capacityFrames)
                    + Int64(transport.marginFrames)
            )
            let startFrame = max(endFrame - Int64(requestedFrames), oldest)
            guard startFrame < endFrame else {
                lastFailure = .windowLost
                break
            }

            if let failure = attempt(from: startFrame) {
                lastFailure = failure
                // Only a lost head is worth restarting; an IO fault will not
                // heal by being repeated.
                guard case .windowLost = failure else { break }
                logger.notice("Tape export pass \(pass) lost the head; restarting further forward")
                continue
            }

            do {
                try? manager.removeItem(at: destination)
                try manager.moveItem(at: partial, to: destination)
            } catch {
                lastFailure = .writeFailed(error.localizedDescription)
                break
            }
            return .success(destination)
        }

        // Never leave a partial file behind for the user to find and trust.
        try? manager.removeItem(at: partial)
        return .failure(lastFailure)
    }

    // MARK: - Naming

    /// `<App Name> <yyyy-MM-dd HH.mm.ss>.wav` (§3-Q5), with the characters a
    /// filename cannot carry folded to `-`.
    nonisolated static func fileName(appName: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var safe = appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // A leading dot would hide the user's own recording from them.
        while safe.hasPrefix(".") { safe.removeFirst() }
        if safe.isEmpty { safe = "FineTune" }
        return "\(safe) \(formatter.string(from: date)).wav"
    }
}
