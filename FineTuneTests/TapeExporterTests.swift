// FineTuneTests/TapeExporterTests.swift
// Offline harness for TapeExporter (Phase 2 spec §7 acceptance test 8, §3-Q5,
// E24/E25/E31). No live audio and no live device: a frame-indexed stereo ramp
// is written into a small ring exactly as the primary HAL callback would, the
// exporter runs against it, and the produced WAV is decoded back and compared
// bit-exactly against the ramp.
//
// House convention: prove ordering, not timing. The writer never races the
// exporter on a background thread here — it is advanced from inside the
// exporter's own `copyChunk` seam, so "the tape kept recording during the
// export" is a deterministic interleaving that means the same thing on any
// machine speed.
//
// Every file these tests create lives in a per-test temporary directory that
// is removed at the end. Nothing is ever written to ~/Music.

import AVFoundation
import Foundation
import Testing
@testable import FineTune

// MARK: - Helpers

private nonisolated let exportRate = 48_000.0
/// 2 s ring; margin is 1 s, so the reachable past is 48 000 frames and the
/// physical slack the exporter races against is another 48 000.
private nonisolated let exportCapacity = 96_000
private nonisolated let reachableFrames = 48_000

/// Frame-indexed stereo ramp: L = n, R = n/2 — exact in Float32 below 2^24
/// frames, and channel-distinct so a channel swap cannot pass.
private nonisolated func rampL(_ n: Int64) -> Float { Float(n) }
private nonisolated func rampR(_ n: Int64) -> Float { Float(n) * 0.5 }

/// Drives the ring the way the primary HAL callback does. `@unchecked
/// Sendable` because the only cross-thread use is inside the exporter's
/// `copyChunk` seam, which is serialized on the exporter's own queue.
private nonisolated final class TapeWriter: @unchecked Sendable {
    let transport: TapeTransportRT

    init(capacityFrames: Int = exportCapacity) {
        transport = TapeTransportRT(
            sampleRate: exportRate,
            capacityFrames: capacityFrames,
            horizonGuardFrames: 16
        )
    }

    /// One pinned-live callback of ramp: the buffer lands in the ring and is
    /// returned untouched, which is the only mode the exporter cares about.
    func write(_ frames: Int) {
        let start = transport.writtenFrames
        var buffer = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            buffer[i * 2] = rampL(start + Int64(i))
            buffer[i * 2 + 1] = rampR(start + Int64(i))
        }
        _ = buffer.withUnsafeMutableBufferPointer {
            transport.writeAndRender(interleavedStereo: $0.baseAddress!, frameCount: frames)
        }
    }

    func write(totalFrames: Int, callback: Int = 512) {
        var remaining = totalFrames
        while remaining > 0 {
            let frames = min(callback, remaining)
            write(frames)
            remaining -= frames
        }
    }
}

/// Decoded interleaved contents of an exported WAV.
private func decode(_ url: URL) throws -> (rate: Double, samples: [Float]) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
    let rate = file.fileFormat.sampleRate
    var samples: [Float] = []
    guard file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192)
    else { return (rate, samples) }
    // `read(into:)` fills at most one internal chunk per call, so it is looped
    // — otherwise the tail of the file silently reads as missing.
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
        samples.append(
            contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength) * 2)
        )
    }
    return (rate, samples)
}

/// nil when the decoded file is exactly the ramp continuing from its own first
/// frame — i.e. coherent, in order, no torn or skipped chunk anywhere.
private func rampMismatch(_ samples: [Float]) -> String? {
    guard !samples.isEmpty else { return "file is empty" }
    let start = Int64(samples[0])
    for i in 0..<(samples.count / 2) {
        let n = start + Int64(i)
        if samples[i * 2] != rampL(n) || samples[i * 2 + 1] != rampR(n) {
            return "frame \(i): got (\(samples[i * 2]), \(samples[i * 2 + 1]))"
                + ", expected (\(rampL(n)), \(rampR(n)))"
        }
    }
    return nil
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TapeExporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Everything in the directory, hidden partials included.
private func entries(of directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// One-shot barrier: the first `holdOnce()` blocks until `open()`, every later
/// one passes straight through.
private nonisolated final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var held = false

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    func holdOnce() {
        lock.lock()
        let already = held
        held = true
        lock.unlock()
        guard !already else { return }
        semaphore.wait()
    }

    func open() { semaphore.signal() }
}

@MainActor
private func waitUntil(
    _ what: String,
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(condition(), "timed out waiting for \(what)")
}

@MainActor
private func makeExporter(in directory: URL, revealed: RevealLog) -> TapeExporter {
    let exporter = TapeExporter()
    exporter.destinationDirectory = directory
    exporter.chunkFrames = 8_192
    exporter.revealInFinder = { revealed.urls.append($0) }
    return exporter
}

@MainActor
private final class RevealLog {
    var urls: [URL] = []
}

private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

// MARK: - The ring reader the exporter is built on (E24)

@Suite("TapeTransportRT — export window reader")
struct TapeWindowReaderTests {

    @Test("Spans outside the ring are refused outright")
    func refusesSpansOutsideTheRing() {
        let writer = TapeWriter()
        writer.write(totalFrames: 116_000)
        let transport = writer.transport
        let written = transport.writtenFrames
        var scratch = [Float](repeating: 0, count: 8_192 * 2)

        scratch.withUnsafeMutableBufferPointer { out in
            let destination = out.baseAddress!
            // One frame below the physical trailing edge: already overwritten.
            #expect(!transport.copyRingWindow(
                from: written - Int64(exportCapacity) - 1, frameCount: 8_192, into: destination
            ))
            // Runs past the write head: those frames do not exist yet.
            #expect(!transport.copyRingWindow(
                from: written - 4_096, frameCount: 8_192, into: destination
            ))
            // Longer than the ring, and degenerate arguments.
            #expect(!transport.copyRingWindow(
                from: 0, frameCount: exportCapacity + 1, into: destination
            ))
            #expect(!transport.copyRingWindow(from: 0, frameCount: 0, into: destination))
            #expect(!transport.copyRingWindow(from: -1, frameCount: 8_192, into: destination))
            // The oldest frame still physically present is readable.
            #expect(transport.copyRingWindow(
                from: written - Int64(exportCapacity), frameCount: 8_192, into: destination
            ))
        }
        #expect(scratch[0] == rampL(written - Int64(exportCapacity)))
        #expect(scratch[1] == rampR(written - Int64(exportCapacity)))
    }

    @Test("Against a live writer, an accepted copy is never torn")
    func acceptedCopiesAreNeverTorn() {
        let writer = TapeWriter()
        writer.write(totalFrames: exportCapacity)
        let transport = writer.transport
        let stop = Flag()
        let thread = Thread { while !stop.isSet { writer.write(512) } }
        thread.stackSize = 512 * 1024
        thread.start()
        defer { stop.set() }

        // Parked 16 frames above the trailing edge: far enough that the
        // pre-copy bounds check passes, close enough that the writer laps the
        // span while the copy is in flight. The only thing then standing
        // between the exporter and a torn file is the post-copy revalidation.
        let frames = 16_384
        var scratch = [Float](repeating: 0, count: frames * 2)
        var accepted = 0
        var torn: String?
        let deadline = Date().addingTimeInterval(5)
        scratch.withUnsafeMutableBufferPointer { out in
            let destination = out.baseAddress!
            for _ in 0..<2_000 {
                if Date() > deadline { break }
                let start = transport.writtenFrames - Int64(exportCapacity) + 16
                guard start >= 0 else { continue }
                guard transport.copyRingWindow(
                    from: start, frameCount: frames, into: destination
                ) else { continue }
                accepted += 1
                for i in 0..<frames {
                    let n = start + Int64(i)
                    if destination[i * 2] != rampL(n) || destination[i * 2 + 1] != rampR(n) {
                        torn = "frame \(n): got \(destination[i * 2]), expected \(rampL(n))"
                        break
                    }
                }
                if torn != nil { break }
            }
        }
        stop.set()
        #expect(torn == nil, "an accepted copy was torn: \(torn ?? "")")
        #expect(accepted > 0, "the reader never accepted a copy — the race was not exercised")
    }
}

// MARK: - Happy path

@Suite("TapeExporter — the window on disk")
@MainActor
struct TapeExporterWindowTests {

    @Test("Exports the requested window bit-exactly and reveals it in Finder")
    func exportsTheWindow() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        writer.write(totalFrames: 60_000)
        let endFrame = writer.transport.writtenFrames

        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)
        let url = try await exporter.export(
            writer.transport, endFrame: endFrame, frameCount: 20_000, appName: "Test App"
        )

        let (rate, samples) = try decode(url)
        #expect(rate == exportRate)
        #expect(samples.count / 2 == 20_000)
        #expect(Int64(samples[0]) == endFrame - 20_000)
        #expect(rampMismatch(samples) == nil)
        #expect(revealed.urls == [url])
        // Nothing partial survives a success either.
        #expect(entries(of: directory) == [url.lastPathComponent])
        #expect(url.lastPathComponent.hasPrefix("Test App "))
        #expect(url.pathExtension == "wav")
    }

    @Test("A window spanning the ring's physical wrap exports in order (E31)")
    func exportsAcrossTheWrapSeam() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        // Past one full lap, so the newest 48 000 frames start at ring index
        // 68 000 and run over the seam at 96 000.
        writer.write(totalFrames: 116_000)
        let endFrame = writer.transport.writtenFrames

        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)
        // One chunk for the whole window: the wrap split is the only thing
        // that can go wrong, so nothing else is in the way of it.
        exporter.chunkFrames = reachableFrames
        let url = try await exporter.export(
            writer.transport, endFrame: endFrame, frameCount: reachableFrames, appName: "Wrap"
        )

        let (_, samples) = try decode(url)
        #expect(samples.count / 2 == reachableFrames)
        #expect(Int64(samples[0]) == endFrame - Int64(reachableFrames))
        #expect(rampMismatch(samples) == nil)
    }

    @Test("Asking for more than the ring holds yields exactly what exists")
    func clampsToWhatExists() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let revealed = RevealLog()

        // Barely-filled ring: the whole tape is younger than the request.
        let young = TapeWriter()
        young.write(totalFrames: 10_000)
        let shortExporter = makeExporter(in: directory, revealed: revealed)
        let shortURL = try await shortExporter.export(
            young.transport, endFrame: young.transport.writtenFrames,
            frameCount: 200_000, appName: "Young"
        )
        let (_, shortSamples) = try decode(shortURL)
        #expect(shortSamples.count / 2 == 10_000)
        #expect(Int64(shortSamples[0]) == 0)
        #expect(rampMismatch(shortSamples) == nil)

        // Long-running ring: the request is clamped to the reachable past,
        // which is capacity minus the 1 s writer margin (§2.3).
        let old = TapeWriter()
        old.write(totalFrames: 200_000)
        let endFrame = old.transport.writtenFrames
        let longExporter = makeExporter(in: directory, revealed: revealed)
        let longURL = try await longExporter.export(
            old.transport, endFrame: endFrame, frameCount: 500_000, appName: "Old"
        )
        let (_, longSamples) = try decode(longURL)
        #expect(longSamples.count / 2 == reachableFrames)
        #expect(Int64(longSamples[0]) == endFrame - Int64(reachableFrames))
        #expect(rampMismatch(longSamples) == nil)
    }
}

// MARK: - Acceptance test 8 (E24)

@Suite("TapeExporter — export under fire")
@MainActor
struct TapeExporterWriterRaceTests {

    @Test("Continuous writing during the export costs only the head (E24)")
    func exportUnderContinuousWriting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        writer.write(totalFrames: 116_000)
        let endFrame = writer.transport.writtenFrames
        // The tape keeps recording between the MainActor snapshot and the
        // moment the utility queue actually gets to the copy.
        let lostBeforeStart = 20_000
        writer.write(totalFrames: lostBeforeStart)

        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)
        // ...and keeps recording between every chunk of the copy itself.
        exporter.copyChunk = { transport, start, count, destination in
            let copied = transport.copyRingWindow(
                from: start, frameCount: count, into: destination
            )
            writer.write(512)
            return copied
        }

        let url = try await exporter.export(
            writer.transport, endFrame: endFrame,
            frameCount: reachableFrames, appName: "Under Fire"
        )

        let (rate, samples) = try decode(url)
        let frames = samples.count / 2
        #expect(rate == exportRate)
        // Coherent: every frame present is the ramp, in order, no seam.
        #expect(rampMismatch(samples) == nil)
        // Shorter at the OLDEST end only — the newest frame is still the one
        // the snapshot named.
        #expect(Int64(samples[0]) == endFrame - Int64(frames))
        // The drop is exactly the head the writer had already overwritten
        // before the copy began; the frames it wrote *during* the copy cost
        // nothing, because they land ahead of the read cursor.
        #expect(reachableFrames - frames == lostBeforeStart)
        #expect(entries(of: directory) == [url.lastPathComponent])
    }

    @Test("A lost head restarts the export further forward rather than failing")
    func aLostHeadRestartsFurtherForward() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        writer.write(totalFrames: 116_000)
        let endFrame = writer.transport.writtenFrames

        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)
        let calls = Counter()
        let overwritten = 12_000
        exporter.copyChunk = { transport, start, count, destination in
            guard calls.next() == 1 else {
                return transport.copyRingWindow(from: start, frameCount: count, into: destination)
            }
            // The writer reached this chunk: the head is gone, and with it the
            // bytes already on disk. The next pass must begin further forward.
            writer.write(totalFrames: overwritten)
            return false
        }

        let url = try await exporter.export(
            writer.transport, endFrame: endFrame,
            frameCount: reachableFrames, appName: "Restarted"
        )
        let (_, samples) = try decode(url)
        let frames = samples.count / 2
        // Shorter at the oldest end by exactly what the writer swallowed, and
        // still ending on the frame the snapshot named.
        #expect(frames == reachableFrames - overwritten)
        #expect(Int64(samples[0]) == endFrame - Int64(frames))
        #expect(rampMismatch(samples) == nil)
        #expect(entries(of: directory) == [url.lastPathComponent])
    }

    @Test("A window lost mid-copy fails cleanly and leaves no partial file")
    func aLostWindowLeavesNothingBehind() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        writer.write(totalFrames: 60_000)

        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)
        // The first chunk copies, everything after it is torn — so a partial
        // file really is written to disk before the failure.
        let calls = Counter()
        exporter.copyChunk = { transport, start, count, destination in
            guard calls.next() == 0 else { return false }
            return transport.copyRingWindow(from: start, frameCount: count, into: destination)
        }

        await #expect(throws: TapeExporter.Failure.windowLost) {
            try await exporter.export(
                writer.transport, endFrame: writer.transport.writtenFrames,
                frameCount: 40_960, appName: "Lost"
            )
        }
        #expect(entries(of: directory).isEmpty, "a partial export must be deleted")
        #expect(revealed.urls.isEmpty)
    }
}

// MARK: - Failure paths

@Suite("TapeExporter — refusals")
@MainActor
struct TapeExporterFailureTests {

    @Test("An empty or not-yet-filled tape is refused")
    func refusesAnEmptyWindow() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)

        await #expect(throws: TapeExporter.Failure.emptyWindow) {
            try await exporter.export(
                writer.transport, endFrame: 0, frameCount: 0, appName: "Empty"
            )
        }
        writer.write(totalFrames: 10_000)
        await #expect(throws: TapeExporter.Failure.emptyWindow) {
            try await exporter.export(
                writer.transport, endFrame: writer.transport.writtenFrames,
                frameCount: 0, appName: "Empty"
            )
        }
        #expect(entries(of: directory).isEmpty)
    }

    @Test("An unwritable destination is refused before anything is copied")
    func refusesAnUnwritableDestination() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file cannot be a parent directory.
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)

        let writer = TapeWriter()
        writer.write(totalFrames: 20_000)
        let revealed = RevealLog()
        let exporter = makeExporter(
            in: blocker.appendingPathComponent("FineTune", isDirectory: true), revealed: revealed
        )

        var caught: TapeExporter.Failure?
        do {
            _ = try await exporter.export(
                writer.transport, endFrame: writer.transport.writtenFrames,
                frameCount: 10_000, appName: "Blocked"
            )
        } catch let failure as TapeExporter.Failure {
            caught = failure
        }
        guard case .destinationNotWritable = try #require(caught) else {
            Issue.record("expected .destinationNotWritable, got \(String(describing: caught))")
            return
        }
        #expect(entries(of: directory) == ["blocker"])
        #expect(revealed.urls.isEmpty)
    }

    @Test("A full volume is refused before a byte is written")
    func refusesAFullVolume() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        writer.write(totalFrames: 60_000)

        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)
        exporter.availableCapacity = { _ in 4_096 }

        var caught: TapeExporter.Failure?
        do {
            _ = try await exporter.export(
                writer.transport, endFrame: writer.transport.writtenFrames,
                frameCount: 40_000, appName: "Full"
            )
        } catch let failure as TapeExporter.Failure {
            caught = failure
        }
        guard case .insufficientSpace(let needed, let available) = try #require(caught) else {
            Issue.record("expected .insufficientSpace, got \(String(describing: caught))")
            return
        }
        #expect(needed == 40_000 * 8 + 4_096)
        #expect(available == 4_096)
        #expect(entries(of: directory).isEmpty)
        #expect(revealed.urls.isEmpty)
    }

    @Test("A second export while one is running is refused, not interleaved")
    func refusesAConcurrentExport() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = TapeWriter()
        writer.write(totalFrames: 60_000)
        let endFrame = writer.transport.writtenFrames

        let revealed = RevealLog()
        let exporter = makeExporter(in: directory, revealed: revealed)
        let gate = Gate()
        exporter.copyChunk = { transport, start, count, destination in
            gate.holdOnce()
            return transport.copyRingWindow(from: start, frameCount: count, into: destination)
        }

        let first = Task { @MainActor in
            try? await exporter.export(
                writer.transport, endFrame: endFrame, frameCount: 20_000, appName: "First"
            )
        }
        await waitUntil("the first export to reach the ring") { gate.isHeld }

        await #expect(throws: TapeExporter.Failure.alreadyRunning) {
            try await exporter.export(
                writer.transport, endFrame: endFrame, frameCount: 20_000, appName: "Second"
            )
        }

        gate.open()
        let url = try #require(await first.value)
        // Exactly one file: the second call never opened one.
        #expect(entries(of: directory) == [url.lastPathComponent])
        #expect(revealed.urls == [url])
    }
}

// MARK: - Naming

@Suite("TapeExporter — destination")
struct TapeExporterNamingTests {

    @Test("The default destination is ~/Music/FineTune (§3-Q5)")
    func defaultDirectoryIsMusicFineTune() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("FineTune", isDirectory: true)
        #expect(TapeExporter.defaultDirectory.standardizedFileURL == expected.standardizedFileURL)
    }

    @Test("Filenames are '<App Name> <yyyy-MM-dd HH.mm.ss>.wav'")
    func fileNameFormat() {
        let date = Date(timeIntervalSince1970: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: date)

        #expect(TapeExporter.fileName(appName: "Spotify", date: date) == "Spotify \(stamp).wav")
        // Characters a filename cannot carry, and a name that would otherwise
        // hide the user's own recording from them.
        #expect(TapeExporter.fileName(appName: "a/b:c", date: date) == "a-b-c \(stamp).wav")
        #expect(TapeExporter.fileName(appName: "  ", date: date) == "FineTune \(stamp).wav")
        #expect(TapeExporter.fileName(appName: ".hidden", date: date) == "hidden \(stamp).wav")
    }
}
