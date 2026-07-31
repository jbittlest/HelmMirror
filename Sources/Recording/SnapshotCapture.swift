//
//  SnapshotCapture.swift
//  HelmMirror
//
//  A still of exactly what is on the mirror, written straight to a JPEG file.
//
//  Why this is not three lines of UIKit
//  ------------------------------------
//  `UIView.drawHierarchy(in:afterScreenUpdates:)` and `UIGraphicsImageRenderer`
//  do NOT capture an `AVSampleBufferDisplayLayer`. Its content is composited by
//  the render server, not by Core Animation's software path, so you get a black
//  rectangle — silently, which is what makes it the most common wrong answer.
//
//  `copyDisplayedPixelBuffer()` (Swift: `displayedPixelBuffer()`) lives on
//  `AVSampleBufferVideoRenderer` and needs iOS 17.4; the deployment target is
//  iOS 16, and even where it exists it is documented to return NULL for
//  protected content, for nothing-displayed, and while the rate is non-zero.
//  So it is a fast path, never the mechanism.
//
//  Retaining "the last CMSampleBuffer" and decoding it alone does not work
//  either: a P-frame is meaningless without its reference chain back to the
//  last IDR.
//
//  The mechanism
//  -------------
//  Keep the CURRENT group of pictures in AVCC form — cleared and restarted at
//  every keyframe, appended to for every unit after it. Decoding that ring
//  end-to-end through a `VTDecompressionSession` reproduces exactly the frame
//  the user is looking at, because the last unit in the ring is the last unit
//  the display layer was handed.
//
//  Cost while armed: one array append and one integer add per frame, bounded at
//  300 frames / 8 MiB (the plotter's GOP at 1280x720 / ~2 Mbit/s is well under
//  1 MiB). Cost while not armed: one uncontended lock and a `Bool` — the ring is
//  empty and no `VTDecompressionSession` exists. Nothing is ever mutated: `Data`
//  values are appended to an array and read back.
//
//  Threading. `noteParameterSets` and `append` run on the RTSP session's serial
//  video queue and must never block it. `isArmed` and `capture` are called from
//  main; the decode and the JPEG write happen on a private serial queue, and the
//  completion is always delivered on main.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Retains the current GOP while armed and turns it into a JPEG on demand.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`, except
/// `displayLayer` (main-thread only, see below) and `session` (decode queue
/// only). Both invariants are enforced by construction in this file.
public final class SnapshotCapture: @unchecked Sendable {

    // MARK: - Types

    public struct Result: Equatable, Sendable {
        public let url: URL
        public let pixelSize: CGSize

        public init(url: URL, pixelSize: CGSize) {
            self.url = url
            self.pixelSize = pixelSize
        }
    }

    public enum Failure: Error, Equatable {
        case notArmed
        case noFrame                 // nothing decodable yet — no keyframe has arrived
        case decodeFailed(OSStatus)
        case encodeFailed
        case writeFailed(String)

        /// Helm-readable, ≤ 60 chars. The machine detail goes to the diagnostics
        /// ring instead, where it can be read without shouting at the skipper.
        public var message: String {
            switch self {
            case .notArmed:     return "The mirror is not running"
            case .noFrame:      return "No picture to save yet"
            case .decodeFailed: return "Could not decode the picture"
            case .encodeFailed: return "Could not create the image"
            case .writeFailed:  return "Could not save the photo"
            }
        }
    }

    // MARK: - Frozen caps

    /// On overflow the ring FREEZES — it keeps what it has and stops appending
    /// until the next keyframe clears it. Truncating the middle of a GOP would
    /// break the reference chain and decode to garbage.
    public static let maxGOPFrames = 300
    public static let maxGOPBytes  = 8 << 20

    // MARK: - Ring

    private struct Frame {
        let avcc: Data
        let ticks: Int64
        let isKeyframe: Bool
    }

    /// Synthetic inter-frame spacing for the ring's private timeline, in the
    /// 90 kHz timescale. The snapshot path does not care about real time — only
    /// about decode order and about which decoded frame is last — so it keeps
    /// its own strictly increasing key rather than sharing `RTPTimeline` with
    /// the recorder. A snapshot must work whether or not a recording is running.
    private static let syntheticTickStep: Int64 = 3000

    // MARK: - Stored state

    private let directory: URL
    private let decodeQueue = DispatchQueue(label: "com.jimmy.helmmirror.snapshot")

    /// Guards every field below it. Only ever held around plain field access —
    /// never across a CoreMedia, VideoToolbox or logging call.
    private let lock = NSLock()
    private var armed = false
    private var ring: [Frame] = []
    private var ringBytes = 0
    private var frozen = false
    private var format: CMVideoFormatDescription?
    private var activeSets = H264ParameterSets()
    private var didLogRingFull = false

    /// Owned by `decodeQueue`, touched nowhere else (and in `deinit`, where
    /// nothing else can reach this object).
    private var session: VTDecompressionSession?

    public init(directory: URL = MirrorRecorder.defaultDirectory) {
        self.directory = directory
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: - Arming

    /// Maintain the ring. Set from MAIN; read on the video queue under the lock.
    /// Setting it to false clears the ring and tears down any decompression
    /// session, so an off-screen mirror retains nothing at all.
    public var isArmed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return armed
        }
        set {
            lock.lock()
            let changed = armed != newValue
            armed = newValue
            if !newValue { clearRingLocked() }
            lock.unlock()

            guard changed, !newValue else { return }
            // Serial queue: this lands after any capture already in flight, which
            // invalidates its own session on the way out. Belt and braces, so the
            // "nothing exists while disarmed" claim above is enforced, not assumed.
            decodeQueue.async { [weak self] in self?.tearDownSession() }
        }
    }

    /// The renderer's layer, for the iOS 17.4+ fast path only. Weak — a snapshot
    /// helper is never a reason to keep a view alive. Set and read on MAIN.
    public weak var displayLayer: AVSampleBufferDisplayLayer?

    // MARK: - The tee (video queue)

    /// Cache the format description the decoder will need. On the video queue.
    public func noteParameterSets(_ sets: H264ParameterSets) {
        lock.lock()
        let unchanged = sets == activeSets
        lock.unlock()
        if unchanged { return }

        guard sets.isComplete else { return }

        let built = H264SampleBuffer.formatDescription(sps: sets.sps, pps: sets.pps)

        lock.lock()
        activeSets = sets                 // cached even on failure, so a broken set
        format = built                    // is not re-parsed and re-logged forever
        // The retained GOP was coded against the previous avcC and cannot be
        // decoded with this one. Drop it; the next keyframe restarts the ring.
        clearRingLocked()
        lock.unlock()

        if built == nil {
            MirrorDiagnostics.shared.log("snap: err bad parameter sets")
        }
    }

    /// Maintain the GOP ring. On the video queue — no allocation beyond the
    /// array's amortised growth, no I/O, no logging except once per overflow.
    public func append(_ unit: H264AccessUnit) {
        guard !unit.isCorrupt else { return }

        lock.lock()
        let overflowed = ingestLocked(unit)
        lock.unlock()

        if overflowed { MirrorDiagnostics.shared.log("snap: gop ring full") }
    }

    /// Returns true when this call is the one that filled the ring, so the
    /// caller can log it after dropping the lock.
    private func ingestLocked(_ unit: H264AccessUnit) -> Bool {
        guard armed else { return false }

        if unit.isKeyframe {
            ring.removeAll(keepingCapacity: true)
            ringBytes = 0
            frozen = false
            didLogRingFull = false
        }

        // Never start mid-GOP: the first entry must be the IDR everything after
        // it references.
        guard !ring.isEmpty || unit.isKeyframe else { return false }
        guard !frozen else { return false }

        if ring.count + 1 > Self.maxGOPFrames || ringBytes + unit.avcc.count > Self.maxGOPBytes {
            frozen = true
            let shouldLog = !didLogRingFull
            didLogRingFull = true
            return shouldLog
        }

        ring.append(Frame(avcc: unit.avcc,
                          ticks: Int64(ring.count) * Self.syntheticTickStep,
                          isKeyframe: unit.isKeyframe))
        ringBytes += unit.avcc.count
        return false
    }

    private func clearRingLocked() {
        ring.removeAll(keepingCapacity: false)
        ringBytes = 0
        frozen = false
        didLogRingFull = false
    }

    // MARK: - Capture

    /// Take a still of the frame currently on screen. Completion on MAIN.
    public func capture(completion: @escaping (Swift.Result<Result, Failure>) -> Void) {
        // The fast path below reads a layer, and the contract says the completion
        // arrives on main; both are simplest if the whole entry point is on main.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return completion(.failure(.notArmed)) }
                self.capture(completion: completion)
            }
            return
        }

        guard isArmed else {
            finish(.failure(.notArmed), completion)
            return
        }

        // 1. Fast path (iOS 17.4+). Nil is the expected answer on many frames —
        //    no diagnostic, just fall through to the ring.
        let displayed = fastPathPixelBuffer()

        // `self` is held strongly for the duration: the work is bounded and the
        // caller is owed exactly one completion.
        decodeQueue.async {
            var image: CGImage?
            if let displayed {
                image = Self.makeImage(from: displayed.buffer)
            }
            if image == nil {
                // 2/3. Ring path — decode the retained GOP end to end.
                switch self.decodeCurrentGOP() {
                case .success(let pixelBuffer):
                    image = Self.makeImage(from: pixelBuffer)
                case .failure(let failure):
                    self.finish(.failure(failure), completion)
                    return
                }
            }
            guard let image else {
                self.finish(.failure(.encodeFailed), completion)
                return
            }
            // 4/5. Encode and write.
            self.finish(self.writeJPEG(image), completion)
        }
    }

    // MARK: - Decode

    /// A hand-off of one CoreVideo buffer from main to `decodeQueue`. CVPixelBuffer
    /// is not `Sendable`; ownership moves with the box and main never touches the
    /// buffer again, which is exactly the narrow escape hatch that keeps strict
    /// concurrency honest without loosening anything else.
    private struct PixelBufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// The iOS 17.4+ fast path: the renderer's own copy of what is on screen.
    /// Main thread only. `displayedPixelBuffer()` is the Swift spelling of
    /// `-copyDisplayedPixelBuffer`, and it legitimately returns nil for protected
    /// content, for nothing-displayed, and on many ordinary frames.
    private func fastPathPixelBuffer() -> PixelBufferBox? {
        guard #available(iOS 17.4, *),
              let buffer = displayLayer?.sampleBufferRenderer.displayedPixelBuffer() else {
            return nil
        }
        return PixelBufferBox(buffer: buffer)
    }

    /// Collects the decoder's output. The VideoToolbox output handler is a
    /// `CM_SWIFT_SENDABLE` block that may be invoked on the decoder's own
    /// threads, so the accumulator has to be a locked reference type rather
    /// than a captured local.
    private final class DecodeSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        private var pts: CMTime = .invalid
        private var failure: OSStatus = noErr

        func accept(status: OSStatus, image: CVImageBuffer?, pts newPTS: CMTime) {
            lock.lock()
            defer { lock.unlock() }
            guard status == noErr, let image else {
                if failure == noErr, status != noErr { failure = status }
                return
            }
            // Keep the GREATEST presentation time, not the last one emitted.
            // Decode order and display order are the same on this stream today;
            // a stream with B-frames would otherwise hand back the wrong frame.
            if buffer == nil || !pts.isValid || CMTimeCompare(newPTS, pts) > 0 {
                buffer = image
                pts = newPTS
            }
        }

        var best: CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }

        var firstFailure: OSStatus {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
    }

    /// Decode the retained GOP and return the newest picture in it.
    /// On `decodeQueue`.
    private func decodeCurrentGOP() -> Swift.Result<CVPixelBuffer, Failure> {
        lock.lock()
        let frames = ring            // value copy: the `Data` elements are shared
        let format = self.format     // COW buffers, so the video queue never waits
        lock.unlock()

        guard let format, let first = frames.first, first.isKeyframe else {
            return .failure(.noFrame)
        }

        // 32BGRA is the format `VTCreateCGImageFromCVPixelBuffer` handles without
        // surprises; the IOSurface request keeps the buffer GPU-backed so the
        // conversion does not fall back to a CPU copy of the whole frame.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()
        ]

        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,          // nil ⇒ the block-based decode call below
            decompressionSessionOut: &created)
        guard createStatus == noErr, let session = created else {
            return .failure(.decodeFailed(createStatus))
        }
        self.session = session
        defer { tearDownSession() }

        let sink = DecodeSink()
        var decodeStatus: OSStatus = noErr

        for frame in frames {
            guard let sample = H264SampleBuffer.make(
                    avcc: frame.avcc,
                    format: format,
                    isKeyframe: frame.isKeyframe,
                    presentationTime: CMTime(value: frame.ticks,
                                             timescale: CMTimeScale(RTPTimeline.timescale)),
                    displayImmediately: false) else {
                decodeStatus = OSStatus(kVTParameterErr)
                break
            }

            let enqueueStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: nil) { status, _, imageBuffer, presentationTime, _ in
                    sink.accept(status: status, image: imageBuffer, pts: presentationTime)
                }
            if enqueueStatus != noErr {
                decodeStatus = enqueueStatus
                break
            }
        }

        VTDecompressionSessionWaitForAsynchronousFrames(session)

        // A partially decoded GOP still yields a usable picture, so anything the
        // decoder managed to emit beats reporting a failure.
        if let best = sink.best { return .success(best) }
        return .failure(.decodeFailed(decodeStatus != noErr ? decodeStatus : sink.firstFailure))
    }

    /// On `decodeQueue`, or on `deinit`'s thread when nothing else can reach it.
    private func tearDownSession() {
        guard let session else { return }
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }

    private static func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return status == noErr ? image : nil
    }

    // MARK: - Encode and write

    /// A file rather than a `UIImage`, so the Photos save and the share-sheet
    /// fallback are exactly the same code as for a recording — and so the still
    /// shows up in the Files app too. On `decodeQueue`.
    private func writeJPEG(_ image: CGImage) -> Swift.Result<Result, Failure> {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        let existing = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
        let name = RecordingNames.unique(RecordingNames.stillFilename(Date(), timeZone: .current),
                                         existing: existing)
        let url = directory.appendingPathComponent(name)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString,
                                                                1,
                                                                nil) else {
            return .failure(.writeFailed("no destination for \(name)"))
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return .failure(.writeFailed("jpeg encode failed"))
        }

        return .success(Result(url: url,
                               pixelSize: CGSize(width: image.width, height: image.height)))
    }

    // MARK: - Completion

    /// One diagnostic line per attempt — never per frame — then the completion
    /// on main.
    private func finish(_ result: Swift.Result<Result, Failure>,
                        _ completion: @escaping (Swift.Result<Result, Failure>) -> Void) {
        switch result {
        case .success(let still):
            MirrorDiagnostics.shared.log("snap: \(still.url.lastPathComponent) " +
                                         "(\(Int(still.pixelSize.width))x\(Int(still.pixelSize.height)))")
        case .failure(let failure):
            MirrorDiagnostics.shared.log("snap: err \(Self.detail(for: failure))")
        }
        DispatchQueue.main.async { completion(result) }
    }

    private static func detail(for failure: Failure) -> String {
        switch failure {
        case .notArmed:                return "not armed"
        case .noFrame:                 return "no keyframe yet"
        case .decodeFailed(let status): return "decode \(status)"
        case .encodeFailed:            return "no image from pixel buffer"
        case .writeFailed(let detail): return detail
        }
    }
}
