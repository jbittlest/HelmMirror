//
//  H264SampleBuffer.swift
//  HelmMirror
//
//  The two CoreMedia constructions the whole app shares (SPEC-RECORDING §3):
//  SPS/PPS → `CMVideoFormatDescription`, and AVCC bytes → `CMSampleBuffer`.
//
//  Both bodies were LIFTED verbatim out of `H264VideoView`, where they have been
//  proven against the real plotter, rather than rewritten. `H264VideoView` keeps
//  its two private statics as one-line forwarders, so the display path's
//  behaviour is byte-identical to before this file existed.
//
//  Two parameters were lifted out of the sample-buffer body, and only two:
//
//    · `presentationTime` replaces the hard-coded `CMTime(rtpTimestamp, 90_000)`.
//      The renderer does not care (nothing is queued to a clock), but a file's
//      sample table is exactly its presentation times, and those have to be the
//      recorder's rebased, strictly monotonic ticks.
//
//    · `displayImmediately` gates the `DisplayImmediately` attachment. The
//      renderer wants it — it is what gives the mirror its latency. A file must
//      NOT have it: it is a hint to a live renderer and has no business in an
//      MP4 sample table.
//
//  `kCMSampleAttachmentKey_NotSync` is still set whenever `isKeyframe == false`,
//  in both cases. That attachment is what populates the MP4 sync-sample table
//  (`stss`), so getting it wrong produces a file that will not scrub — and, for
//  the display layer, one the renderer cannot recover into.
//
//  CoreMedia only. No UIKit, no AVFoundation, no VideoToolbox: the recorder, the
//  snapshot decoder and the renderer all reach it, and none of them should have
//  to drag a framework in behind it.
//

import Foundation
import CoreMedia

/// Stateless CoreMedia construction, shared by the renderer (`H264VideoView`),
/// the passthrough muxer (`MirrorRecorder`) and the snapshot decoder
/// (`SnapshotCapture`).
public enum H264SampleBuffer {

    /// Build a format description from all SPS followed by all PPS.
    ///
    /// Returns nil when the sets are empty or CoreMedia rejects them.
    public static func formatDescription(sps: [Data], pps: [Data]) -> CMVideoFormatDescription? {
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

    /// Wrap AVCC bytes (each NAL prefixed by its 4-byte big-endian length) in a
    /// ready-to-use `CMSampleBuffer`.
    ///
    /// `avcc` is copied into CoreMedia-owned memory, so the caller's `Data` may
    /// go out of scope the moment this returns — which is what lets both tees
    /// retain nothing from the live stream.
    public static func make(avcc: Data,
                            format: CMVideoFormatDescription,
                            isKeyframe: Bool,
                            presentationTime: CMTime,
                            duration: CMTime = .invalid,
                            displayImmediately: Bool) -> CMSampleBuffer? {
        let length = avcc.count
        guard length > 0 else { return nil }

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

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
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

        setAttachments(on: sampleBuffer,
                       isKeyframe: isKeyframe,
                       displayImmediately: displayImmediately)
        return sampleBuffer
    }

    /// Per-sample attachments. These live in a mutable dictionary inside a CFArray,
    /// so they have to be set through the CF API rather than a bridged Swift dict.
    private static func setAttachments(on sampleBuffer: CMSampleBuffer,
                                       isKeyframe: Bool,
                                       displayImmediately: Bool) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let sample = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)

        // Render as soon as the frame decodes. With no control timebase attached,
        // this is what gives the mirror its latency instead of queueing to a clock.
        // A file must not carry it — see the file header.
        if displayImmediately {
            CFDictionarySetValue(sample,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if !isKeyframe {
            CFDictionarySetValue(sample,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }
}
