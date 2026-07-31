//
//  H264VideoView.swift
//  HelmMirror
//
//  The display end of the native RTSP player: a UIView backed by an
//  `AVSampleBufferDisplayLayer` that turns AVCC access units into rendered video.
//
//  Three jobs:
//    1. Build a `CMVideoFormatDescription` from SPS/PPS — from the SDP when the
//       plotter sends `sprop-parameter-sets`, and again from in-band type 7/8
//       NALs when it does not (SPEC §9.4).
//    2. Wrap each access unit in a `CMSampleBuffer` tagged `DisplayImmediately`,
//       so frames are shown as they decode. There is deliberately no control
//       timebase and no rate control: this is a live helm mirror, and a frame
//       that arrives late is worth less than one shown now.
//    3. Notice when the layer wedges — it can enter a failed state that silently
//       refuses every subsequent sample — flush it, and say so, because after a
//       flush the decoder needs a fresh IDR before the picture is valid again.
//
//  Threading. `setParameterSets`, `enqueue`, `flushDisplay` and `reset` are
//  called from the session's video queue; `onVideoSizeChanged`, `onFirstFrame`
//  and `onDecodeFailure` are always delivered on the main queue. `UIView.layer`
//  is main-thread-only, which is exactly why the backing layer is captured once
//  at init: the layer's own enqueue/flush/status members are thread-safe, so the
//  per-frame path never has to touch UIKit.
//
//  No decoding happens here. `AVSampleBufferDisplayLayer` decodes internally; a
//  `VTDecompressionSession` path behind this same `enqueue` signature is the
//  documented fallback (SPEC §9.3) and is deliberately not built yet.
//

import Foundation
import UIKit
import AVFoundation
import CoreMedia

/// A view that renders a live H.264 elementary stream fed to it one access unit
/// at a time, in AVCC form (each NAL prefixed by its 4-byte big-endian length).
///
/// Nothing here knows about RTSP, RTP or sockets — feed it parameter sets and
/// access units from any source.
open class H264VideoView: UIView {

    // MARK: - Backing layer

    public override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    /// The backing layer, captured at init.
    ///
    /// Cached rather than re-read from `self.layer` on every frame because
    /// `UIView.layer` may only be touched on the main thread, while the display
    /// layer's own `enqueue`/`flush`/`status` are documented thread-safe. That
    /// difference is what lets the video queue render without a main-thread hop.
    ///
    /// Implicitly unwrapped, and not a `let`, for one unavoidable reason: UIKit
    /// only creates the backing layer during `super.init`, so it cannot be read
    /// before then — and Swift requires every `let` to be initialized before the
    /// `super.init` call. It is assigned in `commonInit`, before the view can be
    /// reached from any other thread, and is never nil afterwards.
    public private(set) var displayLayer: AVSampleBufferDisplayLayer!

    // MARK: - Published state

    /// Decoded picture size taken from the SPS. `.zero` until the first format
    /// description is built. Read it on the main queue; it is written there.
    public private(set) var videoSize: CGSize = .zero

    /// Fires when the SPS-derived picture size changes. Main queue.
    public var onVideoSizeChanged: ((CGSize) -> Void)?

    /// Fires exactly once per `reset()` cycle, after the first access unit is
    /// successfully handed to the renderer. Main queue.
    public var onFirstFrame: (() -> Void)?

    /// Fires when the renderer rejects the stream or a frame fails to decode.
    /// The caller should treat it as "wait for the next keyframe". Main queue.
    public var onDecodeFailure: ((String) -> Void)?

    // MARK: - State shared with the video queue

    /// Guards every field below. Only ever held around plain field access — never
    /// across a CoreMedia call or a callback — so it cannot deadlock with main.
    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var activeSPS: [Data] = []
    private var activePPS: [Data] = []
    private var reportedSize: CGSize = .zero
    private var didReportFirstFrame = false

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // UIKit creates the backing layer during `super.init`, so it can only be
        // captured afterwards. `layerClass` guarantees the type; a failure here
        // would mean the class contract itself was broken, so it is fatal rather
        // than something the per-frame path has to keep re-checking.
        guard let backing = layer as? AVSampleBufferDisplayLayer else {
            preconditionFailure("layerClass must vend an AVSampleBufferDisplayLayer")
        }
        displayLayer = backing

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        backgroundColor = .black

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layerFailedToDecode(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        // Re-attaching — a rotation that rebuilds the hierarchy, or a return from
        // the background, which tears the decode session down — can leave the
        // renderer wedged, refusing every sample until it is flushed. Reporting
        // the failure is what asks the caller for a fresh keyframe afterwards.
        guard window != nil, let wedged = rendererFailure() else { return }
        flushDisplay()
        report(failure: wedged)
    }

    // MARK: - Parameter sets

    /// Rebuild the `CMVideoFormatDescription` from `sps` + `pps`.
    ///
    /// Returns `false` — doing nothing — when the parameter sets are byte-identical
    /// to the ones already installed, when either list is empty, or when CoreMedia
    /// rejects them. Safe to call from the video queue.
    @discardableResult
    public func setParameterSets(sps: [Data], pps: [Data]) -> Bool {
        guard !sps.isEmpty, !pps.isEmpty else { return false }

        lock.lock()
        let unchanged = formatDescription != nil && sps == activeSPS && pps == activePPS
        lock.unlock()
        if unchanged { return false }

        guard let format = Self.makeFormatDescription(sps: sps, pps: pps) else {
            report(failure: "bad parameter sets (sps \(sps.count), pps \(pps.count))")
            return false
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))

        lock.lock()
        formatDescription = format
        activeSPS = sps
        activePPS = pps
        let sizeChanged = size != reportedSize
        if sizeChanged { reportedSize = size }
        lock.unlock()

        if sizeChanged {
            onMain { view in
                view.videoSize = size
                view.onVideoSizeChanged?(size)
            }
        }
        return true
    }

    /// Build a format description from all SPS followed by all PPS.
    private static func makeFormatDescription(sps: [Data], pps: [Data]) -> CMVideoFormatDescription? {
        let sets = sps + pps
        let total = sets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }

        // One contiguous copy, because pointers taken from the individual `Data`
        // values would only be valid inside their own `withUnsafeBytes` scope and
        // CoreMedia needs them all live at the same instant.
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
        defer { storage.deallocate() }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        pointers.reserveCapacity(sets.count)
        sizes.reserveCapacity(sets.count)

        var offset = 0
        for set in sets {
            set.copyBytes(to: storage + offset, count: set.count)
            pointers.append(UnsafePointer(storage + offset))
            sizes.append(set.count)
            offset += set.count
        }

        var format: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerArray in
            sizes.withUnsafeBufferPointer { sizeArray in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerArray.baseAddress!,
                    parameterSetSizes: sizeArray.baseAddress!,
                    nalUnitHeaderLength: 4,        // AVCC length prefix, matching the depacketizer
                    formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    // MARK: - Frames

    /// Enqueue one AVCC access unit for immediate display.
    ///
    /// Returns `false` when there is no format description yet (parameter sets
    /// have not arrived — SPEC §9.4) or the renderer is in a failed state, in
    /// which case the caller should drop frames until the next keyframe.
    /// Safe to call from the video queue.
    @discardableResult
    public func enqueue(accessUnit: Data, isKeyframe: Bool, rtpTimestamp: UInt32) -> Bool {
        guard !accessUnit.isEmpty else { return false }

        lock.lock()
        let format = formatDescription
        lock.unlock()
        guard let format else { return false }

        if let wedged = rendererFailure() {
            // A failed renderer silently swallows everything until it is flushed,
            // and a flushed renderer needs a fresh IDR before the picture is
            // valid — reporting the failure re-arms the caller's keyframe gate.
            flushDisplay()
            report(failure: wedged)
            return false
        }

        guard let sample = Self.makeSampleBuffer(avcc: accessUnit,
                                                 format: format,
                                                 isKeyframe: isKeyframe,
                                                 rtpTimestamp: rtpTimestamp) else {
            report(failure: "could not wrap a \(accessUnit.count)-byte access unit")
            return false
        }

        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.enqueue(sample)
        } else {
            displayLayer.enqueue(sample)
        }

        lock.lock()
        let isFirst = !didReportFirstFrame
        didReportFirstFrame = true
        lock.unlock()
        if isFirst { onMain { $0.onFirstFrame?() } }

        return true
    }

    /// Wrap AVCC bytes in a ready-to-render `CMSampleBuffer`.
    private static func makeSampleBuffer(avcc: Data,
                                         format: CMVideoFormatDescription,
                                         isKeyframe: Bool,
                                         rtpTimestamp: UInt32) -> CMSampleBuffer? {
        let length = avcc.count

        // Let CoreMedia own the memory and copy into it, rather than keeping the
        // `Data` alive behind a custom block source for the buffer's lifetime.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // The RTP clock is 90 kHz. This timestamp is for logging and debugging
        // only: `DisplayImmediately` below means presentation order is arrival
        // order, so nothing is ever held back waiting for a clock.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(rtpTimestamp), timescale: 90_000),
            decodeTimeStamp: .invalid)
        var sampleSize = length

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        setAttachments(on: sampleBuffer, isKeyframe: isKeyframe)
        return sampleBuffer
    }

    /// Per-sample attachments. These live in a mutable dictionary inside a CFArray,
    /// so they have to be set through the CF API rather than a bridged Swift dict.
    private static func setAttachments(on sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let sample = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)

        // Render as soon as the frame decodes. With no control timebase attached,
        // this is what gives the mirror its latency instead of queueing to a clock.
        CFDictionarySetValue(sample,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        if !isKeyframe {
            CFDictionarySetValue(sample,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }

    // MARK: - Renderer health

    /// Non-nil when the renderer will refuse further samples until it is flushed.
    private func rendererFailure() -> String? {
        if #available(iOS 17.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                return "layer failed: \(renderer.error?.localizedDescription ?? "unknown")"
            }
            if renderer.requiresFlushToResumeDecoding {
                return "layer needs a flush to resume decoding"
            }
        } else {
            if displayLayer.status == .failed {
                return "layer failed: \(displayLayer.error?.localizedDescription ?? "unknown")"
            }
            if displayLayer.requiresFlushToResumeDecoding {
                return "layer needs a flush to resume decoding"
            }
        }
        return nil
    }

    /// Discard everything queued for display. Keeps the format description, so the
    /// next access unit can be enqueued straight away — though it must be a keyframe.
    public func flushDisplay() {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush()
        } else {
            displayLayer.flush()
        }
    }

    /// Flush and drop the format description, so the next SPS/PPS rebuilds it.
    /// Also re-arms `onFirstFrame` for the next attempt.
    public func reset() {
        flushDisplay()
        lock.lock()
        formatDescription = nil
        activeSPS = []
        activePPS = []
        reportedSize = .zero
        didReportFirstFrame = false
        lock.unlock()
        onMain { $0.videoSize = .zero }
    }

    @objc private func layerFailedToDecode(_ note: Notification) {
        let error = note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? Error
        report(failure: "decode error: \(error?.localizedDescription ?? "unknown")")
    }

    private func report(failure: String) {
        onMain { $0.onDecodeFailure?(failure) }
    }

    // MARK: - Main-queue delivery

    /// Deliver `body` on the main queue, inline when already there so that a
    /// caller which sets parameter sets on main sees `videoSize` immediately.
    /// `self` is held weakly: a callback is never worth keeping a dead view alive.
    private func onMain(_ body: @escaping (H264VideoView) -> Void) {
        if Thread.isMainThread {
            body(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                body(self)
            }
        }
    }
}
