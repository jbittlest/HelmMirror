//
//  MirrorRecorder.swift
//  HelmMirror
//
//  A passthrough MP4 muxer for the plotter's own H.264 (SPEC-RECORDING §4).
//
//  The MFD already sends an encoded elementary stream, so recording is a mux,
//  not a capture: an `AVAssetWriterInput` created with `outputSettings: nil`
//  writes the plotter's AVCC bytes straight into the MP4 sample table. No
//  re-encode, no generational loss, one `memcpy` per frame, ~15 MB a minute.
//
//  Four things make that work, and each one is a rule rather than a detail:
//    1. The file must OPEN on a keyframe. `RecorderGate` skips units until an
//       IDR arrives (it never buffers them), because an MP4 whose first sample
//       is not a sync sample will not decode from frame zero anywhere.
//    2. PTS must be strictly monotonic in the writer's timescale. `RTPTimeline`
//       turns the 32-bit 90 kHz RTP clock — which wraps every ~13 h and can be
//       restarted by the plotter — into rebased ticks starting at exactly zero,
//       which is what makes `startSession(atSourceTime: .zero)` exact.
//    3. The track carries exactly ONE format description; the SPS/PPS live in
//       the `avcC` box, written once. New parameter sets therefore end the file
//       cleanly rather than poisoning the rest of it.
//    4. Nothing may block the RTSP session's video queue. `append` does a
//       lock-guarded field read, a pure-value gate/timeline decision and one
//       CoreMedia copy, then hands the sample to a serial writer queue. When
//       recording is off the whole cost is one uncontended `NSLock`.
//
//  Threading: `append`/`noteParameterSets` on the video queue, all file I/O on
//  `writerQueue`, every callback on main. `stateLock` is only ever held around
//  plain field access and pure value-type mutation — never across an
//  AVFoundation call — so it cannot deadlock with main or with the writer.
//
//  This file retains nothing from the stream: `unit.avcc` is copied into
//  CoreMedia-owned memory and the `H264AccessUnit` goes out of scope at the end
//  of `append`. There is no queue of access units anywhere in here.
//

import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// Records the live H.264 stream to an `.mp4` in Documents without re-encoding.
///
/// Create one lazily (recording is off by default and should cost nothing until
/// it is asked for), feed it the same access units the display path gets, and
/// call `start()` / `stop(reason:)`. It finalizes itself on backgrounding, on a
/// format change, on a writer failure and on the storage/duration/size guards.
///
/// The owner must call `noteParameterSets(_:)` with the stream's current SPS/PPS
/// after creating the recorder mid-stream: parameter sets are only re-emitted
/// when they change, so a recorder created between two changes would otherwise
/// never learn the format and would skip every unit with `no format`.
public final class MirrorRecorder: @unchecked Sendable {

    // MARK: - Public types

    public enum State: Equatable, Sendable {
        case idle
        case waitingForKeyframe   // armed; no file exists yet
        case recording            // the writer has at least one sample
        case finishing            // finishWriting in flight
    }

    public struct Result: Equatable, Sendable {
        public let url: URL
        public let duration: TimeInterval
        public let bytes: Int64
        public let frames: Int

        public init(url: URL, duration: TimeInterval, bytes: Int64, frames: Int) {
            self.url = url
            self.duration = duration
            self.bytes = bytes
            self.frames = frames
        }
    }

    // MARK: - Tuning

    /// 3 s of 30 fps video in flight to the writer. Beyond this the filesystem is
    /// not keeping up and unbounded dispatch would eat the RAM of a device that is
    /// already short of storage, so the recorder stops itself instead.
    private static let maxPendingSamples = 90

    /// The guard timer ticks at 2 Hz so the elapsed label counts smoothly; the
    /// storage/duration/size guards are evaluated on every second tick (1 Hz) and
    /// free space is re-read from the volume every tenth (5 s), which is ample
    /// granularity against a 200 MiB floor.
    private static let guardTickInterval: TimeInterval = 0.5
    private static let guardEvaluationEveryNTicks: UInt64 = 2
    private static let freeSpaceRereadEveryNTicks: UInt64 = 10

    /// `rec: skip …` is rate-limited to this. The diagnostics ring is 40 lines and
    /// shared with the RTSP handshake; per-frame logging would erase it.
    private static let skipLogInterval: UInt64 = 1_000_000_000   // ns

    /// The MP4 track's media timescale, identical to the RTP clock so PTS survive
    /// the trip without rounding.
    private static let mediaTimescale = CMTimeScale(RTPTimeline.timescale)

    // MARK: - Configuration

    private let directory: URL
    private let limits: RecordingLimits

    /// Serial: owns the writer, the input, the counters and the guard timer, and
    /// preserves sample order for free.
    private let writerQueue = DispatchQueue(label: "com.jimmy.helmmirror.recorder")

    // MARK: - State shared with the video queue (stateLock)

    private let stateLock = NSLock()
    private var _isActive = false
    private var _state: State = .idle
    private var _format: CMVideoFormatDescription?
    private var _parameterSets: H264ParameterSets?
    private var gate = RecorderGate()
    private var timeline = RTPTimeline()
    private var pendingSamples = 0
    private var lastSkipLogUptime: UInt64 = 0
    /// Bumped by every `start()`. Samples carry the generation they were built
    /// under so a restart that races a still-finalizing file cannot append to it —
    /// or, worse, open a second one from a straggler.
    private var generation: UInt64 = 0

    // MARK: - State owned by writerQueue

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var outputURL: URL?
    private var frames = 0
    private var bytesWritten: Int64 = 0
    private var lastPTS: CMTime = .zero
    private var startedUptime: UInt64?
    private var guardTimer: DispatchSourceTimer?
    private var guardTicks: UInt64 = 0
    private var cachedFreeBytes: Int64 = .max

    // MARK: - Background task (taskLock)

    private let taskLock = NSLock()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundObserver: NSObjectProtocol?

    // MARK: - Callbacks (main)

    public var onStateChanged: ((State) -> Void)?
    /// (elapsed, bytesWritten). ~2 Hz while recording, never while idle.
    public var onProgress: ((TimeInterval, Int64) -> Void)?
    /// `Result` is nil when no usable file was produced. Fires exactly once per
    /// successful `start()`.
    public var onFinished: ((Result?, RecordingStopReason) -> Void)?

    // MARK: - Init

    public init(directory: URL = MirrorRecorder.defaultDirectory,
                limits: RecordingLimits = .helm) {
        self.directory = directory
        self.limits = limits

        // Delivered on main, which is what lets `stop` take the background task
        // synchronously inside the notification handler — before the app can be
        // suspended mid-flush and leave exactly the truncated file this class
        // exists to prevent.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.stop(reason: .backgrounded)
            }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        // A pending writerQueue block retains self, so a finalize in flight keeps
        // this object alive; there is nothing left to close here.
        guardTimer?.cancel()
    }

    // MARK: - Locations

    /// Documents. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
    /// make it visible in the Files app, the fallback when Photos access is off.
    public static var defaultDirectory: URL {
        if let documents = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first {
            return documents
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Free space on `url`'s volume.
    ///
    /// Prefers `.volumeAvailableCapacityForImportantUsageKey`, which accounts for
    /// purgeable space the system would evict for us, and falls back to the raw
    /// capacity. Unreadable metadata returns `Int64.max`: refusing to record
    /// because a resource-value read hiccuped would be worse than letting the
    /// writer report a real out-of-space error.
    public static func availableBytes(at url: URL) -> Int64 {
        // A directory that does not exist yet has no resource values, so walk up
        // to the nearest ancestor that does — same volume, same answer.
        var probe = url
        for _ in 0..<4 {
            if let bytes = volumeCapacity(at: probe) { return bytes }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        MirrorDiagnostics.shared.log("rec: free space unknown")
        return .max
    }

    private static func volumeCapacity(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int64(important)
        }
        if let plain = values.volumeAvailableCapacity {
            return Int64(plain)
        }
        return nil
    }

    // MARK: - Public state

    /// Read from the video queue on every frame; this is the entire cost of the
    /// recorder existing while it is switched off.
    public var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isActive
    }

    // MARK: - Start / stop

    /// Arm the recorder. The file is created by the first keyframe, not here.
    ///
    /// Returns nil when armed; a non-nil refusal means nothing changed and there
    /// is nothing to finalize.
    @discardableResult
    public func start() -> RecordingStartRefusal? {
        stateLock.lock()
        let alreadyActive = _isActive
        stateLock.unlock()
        if alreadyActive { return nil }

        ensureDirectory()
        let free = Self.availableBytes(at: directory)
        if let refusal = RecordingGuards.canStart(freeBytes: free, limits: limits) {
            MirrorDiagnostics.shared.log("rec: err \(refusal.message)")
            return refusal
        }

        stateLock.lock()
        _isActive = true
        generation &+= 1
        gate.reset()
        timeline.reset()
        pendingSamples = 0
        lastSkipLogUptime = 0
        stateLock.unlock()

        writerQueue.async { [weak self] in
            guard let self else { return }
            self.frames = 0
            self.bytesWritten = 0
            self.lastPTS = .zero
            self.startedUptime = nil
            self.guardTicks = 0
            self.cachedFreeBytes = free
            self.startGuardTimer()
        }

        setState(.waitingForKeyframe)
        MirrorDiagnostics.shared.log("rec: armed — waiting for keyframe")
        return nil
    }

    /// Finalize and close. Idempotent, safe from any thread; `onFinished` fires on
    /// main once the file is actually closed.
    public func stop(reason: RecordingStopReason) {
        stateLock.lock()
        guard _isActive else { stateLock.unlock(); return }
        _isActive = false                      // the video queue stops feeding within one frame
        let gen = generation
        stateLock.unlock()

        // Take the background assertion on main and dispatch the finalize from
        // inside that block, so the assertion is always held before finishWriting
        // starts. When the trigger is backgrounding this runs inline in the
        // notification handler, which is the case that matters.
        runOnMain { [self] in
            beginBackgroundTask()
            writerQueue.async { [self] in
                finish(reason: reason, generation: gen)
            }
        }
    }

    // MARK: - The tee: parameter sets

    /// Called on the RTSP session's video queue, after the display path.
    public func noteParameterSets(_ sets: H264ParameterSets) {
        guard sets.isComplete else {
            MirrorDiagnostics.shared.log("rec: err parameter sets incomplete")
            return
        }

        stateLock.lock()
        let unchanged = _format != nil && _parameterSets == sets
        stateLock.unlock()
        // The depacketizer already filters repeats, but the SDP path can deliver
        // the same sets a second time. Belt and braces.
        if unchanged { return }

        guard let format = H264SampleBuffer.formatDescription(sps: sets.sps, pps: sets.pps) else {
            MirrorDiagnostics.shared.log("rec: err bad parameter sets "
                                         + "(sps \(sets.sps.count), pps \(sets.pps.count))")
            return
        }

        stateLock.lock()
        let hadFormat = _format != nil
        _parameterSets = sets
        _format = format
        let active = _isActive
        stateLock.unlock()

        // A genuine change while armed goes to the gate: once anything has been
        // written the open file's `avcC` cannot describe the new stream, so the
        // gate ends the file rather than filling it with undecodable samples.
        // The first sets to arrive are not a change — nothing to reconcile.
        guard active, hadFormat else { return }
        feedGate(.parameterSetsChanged)
    }

    // MARK: - The tee: frames

    /// Called on the RTSP session's video queue, after the display path. Never
    /// blocks: everything here is a lock-guarded field access, a pure value-type
    /// decision, one CoreMedia copy and an async hand-off.
    public func append(_ unit: H264AccessUnit) {
        switch plan(for: unit) {

        case .inactive:
            return

        case .skip(let reason, let skips):
            logSkip(reason, skips: skips)

        case .finish(let reason):
            // "format changed" is the only finish the gate raises after a write;
            // the other is the opening keyframe never arriving.
            stop(reason: reason == "format changed" ? .formatChanged : .noKeyframe)

        case .write(let format, let ticks, let gen):
            let pts = CMTime(value: CMTimeValue(ticks), timescale: Self.mediaTimescale)
            // Copies `unit.avcc` into CoreMedia-owned memory. No reference to the
            // access unit outlives this call.
            guard let buffer = H264SampleBuffer.make(avcc: unit.avcc,
                                                     format: format,
                                                     isKeyframe: unit.isKeyframe,
                                                     presentationTime: pts,
                                                     displayImmediately: false) else {
                // Treat it as writer pressure: re-arm the keyframe gate so the
                // file resyncs at the next IDR instead of writing a hole.
                feedGate(.writerBusy, logAs: "sample build failed")
                return
            }
            dispatch(buffer: buffer, pts: pts, bytes: unit.avcc.count, generation: gen)
        }
    }

    /// What `append` should do, decided in one lock section so the gate and the
    /// timeline can never be observed half-updated.
    private enum AppendPlan {
        case inactive
        case skip(reason: String, skips: Int)
        case finish(reason: String)
        case write(format: CMVideoFormatDescription, ticks: Int64, generation: UInt64)
    }

    private func plan(for unit: H264AccessUnit) -> AppendPlan {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard _isActive else { return .inactive }
        guard let format = _format else {
            return .skip(reason: "no format", skips: gate.skipsSinceLastWrite)
        }

        switch gate.decide(.accessUnit(isKeyframe: unit.isKeyframe, isCorrupt: unit.isCorrupt)) {
        case .skip(let reason):
            return .skip(reason: reason, skips: gate.skipsSinceLastWrite)
        case .finish(let reason):
            return .finish(reason: reason)
        case .write:
            let outcome = timeline.push(unit.rtpTimestamp)
            guard let ticks = outcome.ticks else {
                // Backwards or a clock discontinuity: AVAssetWriter would refuse
                // the sample outright, so drop it and resync at the next IDR.
                let reason: String
                if case .skip(let gateReason) = gate.decide(.timelineRejected) {
                    reason = gateReason
                } else {
                    reason = "timestamp out of order"
                }
                return .skip(reason: reason, skips: gate.skipsSinceLastWrite)
            }
            return .write(format: format, ticks: ticks, generation: generation)
        }
    }

    private func dispatch(buffer: CMSampleBuffer, pts: CMTime, bytes: Int, generation gen: UInt64) {
        stateLock.lock()
        gate.confirmWrite()
        pendingSamples += 1
        let pending = pendingSamples
        stateLock.unlock()

        guard pending <= Self.maxPendingSamples else {
            stateLock.lock()
            pendingSamples -= 1
            stateLock.unlock()
            MirrorDiagnostics.shared.log("rec: err writer backlog")
            stop(reason: .writerFailed("writer backlog"))
            return
        }

        let sample = Sample(buffer: buffer, pts: pts, bytes: bytes, generation: gen)
        writerQueue.async { [weak self] in
            self?.write(sample)
        }
    }

    /// The hand-off across queues. `CMSampleBuffer` is a reference type CoreMedia
    /// guarantees is safe to pass between threads; this box says so out loud so
    /// the file needs no other concurrency escape hatches.
    private struct Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let pts: CMTime
        let bytes: Int
        let generation: UInt64
    }

    /// The same escape hatch for the finalize completion, which AVFoundation calls
    /// on a queue of its own choosing and where only `status` and `error` are read.
    private struct WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter
    }

    // MARK: - Writing (writerQueue)

    private func write(_ sample: Sample) {
        stateLock.lock()
        pendingSamples = max(0, pendingSamples - 1)
        let currentGeneration = generation
        let active = _isActive
        stateLock.unlock()

        // A straggler from a previous arming must never touch this file — and
        // must certainly never open a new one.
        guard sample.generation == currentGeneration else { return }

        if writer == nil {
            // A stop raced the first sample: opening a file we are about to close
            // would produce exactly the one-frame litter §4.6 forbids.
            guard active else { return }
            guard let format = CMSampleBufferGetFormatDescription(sample.buffer) else {
                fail("no format on first sample")
                return
            }
            guard openFile(format: format) else { return }
        }

        guard let writer, let input else { return }
        guard writer.status == .writing else {
            fail(writer.error?.localizedDescription ?? "writer stopped")
            return
        }

        // With `expectsMediaDataInRealTime` and passthrough this is effectively
        // always true; "effectively" is not "always" on a boat.
        guard input.isReadyForMoreMediaData else {
            feedGate(.writerBusy)
            return
        }
        guard input.append(sample.buffer) else {
            fail(writer.error?.localizedDescription ?? "append rejected")
            return
        }

        frames += 1
        bytesWritten += Int64(sample.bytes)
        lastPTS = sample.pts

        if frames == 1 {
            startedUptime = DispatchTime.now().uptimeNanoseconds
            setState(.recording)
        }
    }

    private func openFile(format: CMVideoFormatDescription) -> Bool {
        ensureDirectory()
        let name = RecordingNames.unique(RecordingNames.videoFilename(Date(), timeZone: .current),
                                         existing: existingNames())
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)   // AVAssetWriter refuses an existing file

        do {
            let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            assetWriter.shouldOptimizeForNetworkUse = false   // no faststart rewrite on finalize
            // Flush a self-describing fragment every 5 s: if iOS kills the app
            // mid-recording, what is on disk is a playable prefix rather than a
            // header-less carcass. This is the one failure the app cannot handle
            // in code, so it is handled in the file format.
            assetWriter.movieFragmentInterval = CMTime(value: 5, timescale: 1)

            let assetInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: nil,   // ← PASSTHROUGH
                                                sourceFormatHint: format)
            assetInput.expectsMediaDataInRealTime = true
            assetInput.mediaTimeScale = Self.mediaTimescale   // exact 90 kHz PTS, no rounding

            guard assetWriter.canAdd(assetInput) else { throw RecorderError.cannotAddInput }
            assetWriter.add(assetInput)
            guard assetWriter.startWriting() else {
                throw assetWriter.error ?? RecorderError.cannotStartWriting
            }
            // The timeline rebases to zero, so the first sample sits exactly here.
            assetWriter.startSession(atSourceTime: .zero)

            writer = assetWriter
            input = assetInput
            outputURL = url
            MirrorDiagnostics.shared.log("rec: start \(name)")
            return true
        } catch {
            removeFile(at: url)
            writer = nil
            input = nil
            outputURL = nil
            fail(error.localizedDescription)
            return false
        }
    }

    /// A writer-side failure. Logs, then stops — which finalizes or deletes,
    /// whichever the file deserves.
    private func fail(_ detail: String) {
        let short = Self.trimmed(detail)
        MirrorDiagnostics.shared.log("rec: err \(short)")
        stop(reason: .writerFailed(short))
    }

    // MARK: - Finalizing (writerQueue)

    private func finish(reason: RecordingStopReason, generation gen: UInt64) {
        stopGuardTimer()
        MirrorDiagnostics.shared.log("rec: stop — \(reason.message)")

        guard let writer, let input, let url = outputURL else {
            // Armed but never opened — nothing written, nothing left behind.
            clearWriterState()
            setState(.idle, ifGeneration: gen)
            endBackgroundTask()
            deliverFinished(nil, reason)
            return
        }

        let frameCount = frames
        let lastValue = lastPTS.value
        let tail = nominalFrameDurationTicks()
        // Detach before the async finalize so a restart begins from a clean slate
        // rather than appending into a file that is already closing.
        clearWriterState()
        setState(.finishing, ifGeneration: gen)

        guard writer.status == .writing else {
            let detail = Self.trimmed(writer.error?.localizedDescription ?? "writer stopped")
            removeFile(at: url)
            MirrorDiagnostics.shared.log("rec: err \(detail)")
            setState(.idle, ifGeneration: gen)
            endBackgroundTask()
            deliverFinished(nil, .writerFailed(detail))
            return
        }

        input.markAsFinished()
        // Give the last picture a real duration, otherwise endSession truncates it.
        writer.endSession(atSourceTime: CMTime(value: lastValue + tail,
                                               timescale: Self.mediaTimescale))
        let box = WriterBox(writer: writer)
        writer.finishWriting { [self] in
            let size = Self.fileSize(at: url)
            let duration = Double(lastValue) / Double(RTPTimeline.timescale)

            if box.writer.status == .completed, frameCount >= 2, size > 0 {
                MirrorDiagnostics.shared.log("rec: wrote \(frameCount) frames, "
                                             + "\(RecordingNames.elapsedLabel(duration)), "
                                             + "\(RecordingByteScale.megabytes(size)) MB")
                setState(.idle, ifGeneration: gen)
                endBackgroundTask()
                deliverFinished(Result(url: url,
                                       duration: duration,
                                       bytes: size,
                                       frames: frameCount),
                                reason)
            } else {
                // A one-frame or zero-byte MP4 in the user's Documents is litter
                // that looks like a bug. Delete it and say so.
                let detail = Self.trimmed(box.writer.error?.localizedDescription ?? "empty file")
                removeFile(at: url)
                MirrorDiagnostics.shared.log("rec: err \(detail)")
                setState(.idle, ifGeneration: gen)
                endBackgroundTask()
                deliverFinished(nil, .writerFailed(detail))
            }
        }
    }

    private func clearWriterState() {
        writer = nil
        input = nil
        outputURL = nil
        frames = 0
        bytesWritten = 0
        lastPTS = .zero
        startedUptime = nil
    }

    // MARK: - Guard timer (writerQueue)

    private func startGuardTimer() {
        stopGuardTimer()
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + Self.guardTickInterval,
                       repeating: Self.guardTickInterval,
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.guardTick() }
        guardTimer = timer
        timer.resume()
    }

    private func stopGuardTimer() {
        guardTimer?.cancel()
        guardTimer = nil
    }

    private func guardTick() {
        guardTicks &+= 1
        let elapsed = currentElapsed()
        let written = bytesWritten

        deliverProgress(elapsed, written)

        guard guardTicks % Self.guardEvaluationEveryNTicks == 0 else { return }
        if guardTicks % Self.freeSpaceRereadEveryNTicks == 0 {
            cachedFreeBytes = Self.availableBytes(at: directory)
        }
        if let reason = RecordingGuards.stopReason(elapsed: elapsed,
                                                   bytesWritten: written,
                                                   freeBytes: cachedFreeBytes,
                                                   limits: limits) {
            stop(reason: reason)
        }
    }

    /// Wall clock since the first written sample, not media time: a stall must
    /// still count against the 30-minute limit, and MP4 expresses the gap as a
    /// longer sample duration anyway, so the two agree in the finished file.
    private func currentElapsed() -> TimeInterval {
        guard let startedUptime else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        return TimeInterval(now &- startedUptime) / 1_000_000_000
    }

    // MARK: - Gate feedback

    private func feedGate(_ event: RecorderGateEvent, logAs override: String? = nil) {
        stateLock.lock()
        let decision = gate.decide(event)
        let skips = gate.skipsSinceLastWrite
        stateLock.unlock()

        switch decision {
        case .write:
            return
        case .skip(let reason):
            logSkip(override ?? reason, skips: skips)
        case .finish(let reason):
            stop(reason: reason == "format changed" ? .formatChanged : .noKeyframe)
        }
    }

    private func logSkip(_ reason: String, skips: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        stateLock.lock()
        let due = lastSkipLogUptime == 0 || now &- lastSkipLogUptime >= Self.skipLogInterval
        if due { lastSkipLogUptime = now }
        stateLock.unlock()
        guard due else { return }
        MirrorDiagnostics.shared.log("rec: skip \(reason) (\(skips) since last write)")
    }

    private func nominalFrameDurationTicks() -> Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return timeline.nominalFrameDurationTicks
    }

    // MARK: - State and delivery

    private func setState(_ new: State) {
        stateLock.lock()
        guard _state != new else { stateLock.unlock(); return }
        _state = new
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(new) }
    }

    /// Only apply the transition if it still belongs to the current arming — a
    /// finalize completing after a restart must not stamp `.idle` over it.
    private func setState(_ new: State, ifGeneration gen: UInt64) {
        stateLock.lock()
        let current = generation
        stateLock.unlock()
        guard current == gen else { return }
        setState(new)
    }

    private func deliverProgress(_ elapsed: TimeInterval, _ bytes: Int64) {
        DispatchQueue.main.async { [weak self] in self?.onProgress?(elapsed, bytes) }
    }

    /// Strong `self`: this fires exactly once per successful `start()` and losing
    /// it would leave the UI recording forever.
    private func deliverFinished(_ result: Result?, _ reason: RecordingStopReason) {
        DispatchQueue.main.async { [self] in onFinished?(result, reason) }
    }

    /// Deliberately not `@Sendable`: the two callers hand it UIKit work, and
    /// `UIApplication.shared` is main-actor isolated, so a `@Sendable` closure
    /// would only trade a queue hop for a concurrency warning. The hop itself is
    /// what makes the call main-thread correct.
    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    // MARK: - Background task

    /// Main queue only. Without this, a stop triggered by backgrounding is killed
    /// mid-flush and produces the corrupt file §4.6 forbids.
    private func beginBackgroundTask() {
        taskLock.lock()
        let existing = backgroundTask
        taskLock.unlock()
        // One assertion covers one finalize; overlapping finalizes (a restart
        // racing a close) finish inside the same window.
        guard existing == .invalid else { return }

        let token = UIApplication.shared.beginBackgroundTask(withName: "HelmMirror.finishRecording") {
            [weak self] in
            // Expired before finishWriting returned. Ending the assertion is all
            // we can do; the 5 s fragments mean the file is still a playable prefix.
            self?.endBackgroundTask()
        }
        taskLock.lock()
        backgroundTask = token
        taskLock.unlock()
    }

    private func endBackgroundTask() {
        taskLock.lock()
        let token = backgroundTask
        backgroundTask = .invalid
        taskLock.unlock()
        guard token != .invalid else { return }
        runOnMain { UIApplication.shared.endBackgroundTask(token) }
    }

    // MARK: - Filesystem helpers

    private func ensureDirectory() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func existingNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// Keeps `rec:` lines inside the 110-character diagnostics budget and leaves
    /// room for `.writerFailed(_).message` to stay inside its own 60-character
    /// contract once the pure layer has prefixed "Recording failed: ".
    private static func trimmed(_ text: String, limit: Int = 40) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "unknown" }
        return RecordingByteScale.clamp(flat, to: limit)
    }

    private enum RecorderError: Error, LocalizedError {
        case cannotAddInput
        case cannotStartWriting

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:     return "writer rejected the video track"
            case .cannotStartWriting: return "writer would not start"
            }
        }
    }
}
