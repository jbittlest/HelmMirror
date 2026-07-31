//
//  RecordingClock.swift
//  HelmMirror
//
//  The pure layer under passthrough recording and snapshots — SPEC-RECORDING §2
//  (the file the spec's file map calls `RecordingCore.swift`).
//
//  FOUNDATION ONLY. No Network, no CoreMedia, no VideoToolbox, no AVFoundation,
//  no Photos, no ImageIO, no UIKit, no SwiftUI. No logging, no clocks, no file
//  system, no DateFormatter. Value types and pure functions, so every rule here
//  is pinned by `swift run helmverify` on a Mac that has only the Command Line
//  Tools. Callers log; this file returns decisions.
//
//  What lives here:
//
//    · `RTPTimeline`   — 90 kHz RTP timestamps → strictly monotonic media ticks,
//                        wrap-safe and rebased to zero (requirement 2)
//    · `RecorderGate`  — keyframe gating and end-of-file conditions (requirement 1)
//    · `RecordingNames`— deterministic, locale-free filenames and labels
//    · `RecordingGuards` — free space, duration and size guards (requirement 6)
//
//  Frozen interface: SPEC-RECORDING §2. Every declaration below is vectored in
//  Verify/main.swift §8; changing a boundary here changes a vector there.
//

import Foundation

// MARK: - RTP timeline

/// What `RTPTimeline.push` did with one access unit's RTP timestamp.
public enum RTPTimelineOutcome: Equatable, Sendable {
    /// The origin was just established. `ticks` is always 0.
    case first(ticks: Int64)
    /// Normal forward progress.
    case advanced(ticks: Int64)
    /// The RTP timestamp repeated. Nudged forward by exactly one tick so the
    /// stream stays strictly monotonic without discarding a picture.
    case coalesced(ticks: Int64)
    /// The RTP timestamp went backwards. Timeline state is UNCHANGED.
    case rejectedBackwards(by: Int64)
    /// Forward jump beyond `RTPTimeline.maxForwardJumpTicks` — the plotter's clock
    /// moved, not time. Timeline state is UNCHANGED.
    case discontinuity(by: Int64)

    /// Media ticks for the accepted cases, nil for the two rejections.
    public var ticks: Int64? {
        switch self {
        case .first(let t), .advanced(let t), .coalesced(let t):
            return t
        case .rejectedBackwards, .discontinuity:
            return nil
        }
    }

    /// True for `.rejectedBackwards` and `.discontinuity`.
    public var isRejection: Bool {
        switch self {
        case .rejectedBackwards, .discontinuity:
            return true
        case .first, .advanced, .coalesced:
            return false
        }
    }
}

/// 90 kHz RTP timestamps → strictly monotonic media ticks.
///
/// The RTP clock is 90 kHz, 32 bits, and wraps roughly every 13 h 15 m. It can
/// also be restarted by the plotter. `AVAssetWriter` refuses a sample whose PTS
/// is not strictly greater than the previous one, so this type is the whole
/// answer to requirement 2.
///
/// Rebasing to zero is implicit: ticks accumulate from the first accepted
/// timestamp, so the first written sample sits at exactly
/// `CMTime(value: 0, timescale: 90_000)` and the writer's
/// `startSession(atSourceTime: .zero)` is exact.
public struct RTPTimeline: Equatable, Sendable {

    /// The RTP clock rate for H.264. Also the MP4 track's media timescale.
    public static let timescale: Int64 = 90_000

    /// 60 s at 90 kHz. Beyond this a forward delta is a clock discontinuity, not a gap:
    /// the RTSP session declares the stream `.ended` after 10 s of silence, so a real
    /// gap can never legitimately exceed a minute.
    public static let maxForwardJumpTicks: Int64 = 5_400_000

    /// 30 fps at 90 kHz — the assumed frame duration until one has been measured.
    private static let defaultFrameDurationTicks: Int64 = 3_000
    /// 60 fps at 90 kHz.
    private static let minFrameDurationTicks: Int64 = 1_500
    /// 10 fps at 90 kHz.
    private static let maxFrameDurationTicks: Int64 = 9_000

    /// -1 until the first accepted timestamp.
    public private(set) var lastEmittedTicks: Int64
    /// The most recent accepted non-zero inter-frame delta, in ticks. 0 until one exists.
    public private(set) var lastFrameDeltaTicks: Int64

    /// The last accepted RTP timestamp; the origin itself is never needed again,
    /// because ticks accumulate rather than subtract.
    private var lastRTPTimestamp: UInt32
    private var hasOrigin: Bool

    public init() {
        lastEmittedTicks = -1
        lastFrameDeltaTicks = 0
        lastRTPTimestamp = 0
        hasOrigin = false
    }

    public mutating func reset() {
        self = RTPTimeline()
    }

    /// Feed one access unit's `rtpTimestamp`.
    public mutating func push(_ rtpTimestamp: UInt32) -> RTPTimelineOutcome {
        guard hasOrigin else {
            hasOrigin = true
            lastRTPTimestamp = rtpTimestamp
            lastEmittedTicks = 0
            lastFrameDeltaTicks = 0
            return .first(ticks: 0)
        }

        // The entire wraparound story: the unsigned difference of two 32-bit
        // counters reinterpreted as signed gives the shortest signed distance,
        // so 0xFFFF_F000 → 0x0000_1000 is +8192, not -4294959104.
        let delta = Int64(Int32(bitPattern: rtpTimestamp &- lastRTPTimestamp))

        // Both rejections leave the timeline exactly as it was, so the next
        // sane timestamp continues from where the file already is.
        if delta > RTPTimeline.maxForwardJumpTicks { return .discontinuity(by: delta) }
        if delta < 0 { return .rejectedBackwards(by: -delta) }

        var ticks = lastEmittedTicks + delta
        if ticks <= lastEmittedTicks {
            // delta == 0: the same picture timestamp twice. One tick forward keeps
            // the writer happy without throwing a picture away.
            ticks = lastEmittedTicks + 1
        }

        lastRTPTimestamp = rtpTimestamp
        if delta > 0 { lastFrameDeltaTicks = delta }
        lastEmittedTicks = ticks

        return delta == 0 ? .coalesced(ticks: ticks) : .advanced(ticks: ticks)
    }

    /// A defensible duration for the final sample, so `endSession(atSourceTime:)` does
    /// not truncate the last frame. `lastFrameDeltaTicks` clamped to 1500...9000
    /// (60 fps ... 10 fps); 3000 (30 fps) when no delta has been observed yet.
    public var nominalFrameDurationTicks: Int64 {
        guard lastFrameDeltaTicks > 0 else { return RTPTimeline.defaultFrameDurationTicks }
        return min(max(lastFrameDeltaTicks, RTPTimeline.minFrameDurationTicks),
                   RTPTimeline.maxFrameDurationTicks)
    }
}

// MARK: - Recorder gate

/// Everything that can happen to the recorder between two written samples.
public enum RecorderGateEvent: Equatable, Sendable {
    case accessUnit(isKeyframe: Bool, isCorrupt: Bool)
    /// SPS/PPS bytes differ from the ones the open file's format description was built from.
    case parameterSetsChanged
    /// `AVAssetWriterInput.isReadyForMoreMediaData` was false.
    case writerBusy
    /// `RTPTimeline.push` returned a rejection.
    case timelineRejected
}

/// What the caller must do with the unit it is holding.
public enum RecorderGateDecision: Equatable, Sendable {
    /// Eligible. The caller MUST then call exactly one of `confirmWrite()`,
    /// `decide(.writerBusy)` or `decide(.timelineRejected)`.
    case write
    /// Drop this unit. `reason` is ≤ 24 chars and safe for the on-screen log.
    case skip(reason: String)
    /// Finalize the file cleanly and stop. Recording does NOT auto-restart.
    case finish(reason: String)
}

/// Keyframe gating and end-of-file conditions — requirement 1 in one type.
///
/// Starting a passthrough file mid-GOP produces an MP4 whose first sync sample is
/// missing; it will not decode from the beginning in QuickTime, Photos or anything
/// else. This gate **skips**, never buffers — buffering would mean retaining
/// access-unit data before the user has even committed to a recording.
public struct RecorderGate: Equatable, Sendable {

    /// Give up waiting for the opening keyframe after this many skipped units
    /// (300 ≈ 10 s at 30 fps). Prevents a "recording" state that never makes a file.
    public static let maxSkipsBeforeFirstWrite = 300

    public private(set) var hasWritten: Bool
    public private(set) var needsKeyframe: Bool
    public private(set) var skipsSinceLastWrite: Int

    public init() {
        hasWritten = false
        needsKeyframe = true
        skipsSinceLastWrite = 0
    }

    public mutating func reset() {
        self = RecorderGate()
    }

    public mutating func decide(_ event: RecorderGateEvent) -> RecorderGateDecision {
        switch event {

        case .accessUnit(let isKeyframe, let isCorrupt):
            // A corrupt unit was assembled with slices missing. Writing it puts an
            // undecodable sample in the file and poisons every P-frame that
            // references it, so it is dropped and the file resyncs at the next IDR.
            // (`RTSPVideoSession` already drops these before `onAccessUnit` fires;
            // this branch is here so the recorder is correct on its own terms.)
            if isCorrupt {
                needsKeyframe = true
                skipsSinceLastWrite += 1
                return .skip(reason: "corrupt frame")
            }
            if needsKeyframe && !isKeyframe {
                skipsSinceLastWrite += 1
                if !hasWritten {
                    return skipsSinceLastWrite > RecorderGate.maxSkipsBeforeFirstWrite
                        ? .finish(reason: "no keyframe arrived")
                        : .skip(reason: "waiting for keyframe")
                }
                return .skip(reason: "resyncing")
            }
            return .write

        case .parameterSetsChanged:
            // A passthrough track carries exactly one CMVideoFormatDescription for
            // its whole length; the SPS/PPS live in the avcC box, written once. New
            // parameter sets cannot be expressed in the open file, so it ends cleanly
            // rather than accumulating samples the avcC cannot describe.
            if hasWritten { return .finish(reason: "format changed") }
            needsKeyframe = true
            return .skip(reason: "format settling")

        case .writerBusy:
            needsKeyframe = true
            skipsSinceLastWrite += 1
            return .skip(reason: "writer busy")

        case .timelineRejected:
            needsKeyframe = true
            skipsSinceLastWrite += 1
            return .skip(reason: "timestamp out of order")
        }
    }

    /// Call only after a `.write` decision was actually handed to the writer.
    public mutating func confirmWrite() {
        hasWritten = true
        needsKeyframe = false
        skipsSinceLastWrite = 0
    }
}

// MARK: - Names

/// Deterministic filenames and labels.
///
/// No `DateFormatter`: locale, calendar and 12/24-hour settings all leak into it,
/// and a filename that changes with the user's region is not vector-testable.
/// `Calendar(identifier: .gregorian)` with an explicit `timeZone` plus
/// `String(format:)` is deterministic. Callers pass `TimeZone.current`; vectors
/// pass a fixed zone.
public enum RecordingNames {

    public static let prefix = "HelmMirror"

    /// "2026-07-25-172000" — sortable, no colons, no spaces, filesystem- and URL-safe.
    public static func timestampComponent(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                        from: date)
        return String(format: "%04d-%02d-%02d-%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// "HelmMirror-2026-07-25-172000.mp4"
    public static func videoFilename(_ date: Date, timeZone: TimeZone) -> String {
        "\(prefix)-\(timestampComponent(date, timeZone: timeZone)).mp4"
    }

    /// "HelmMirror-2026-07-25-172013.jpg"
    public static func stillFilename(_ date: Date, timeZone: TimeZone) -> String {
        "\(prefix)-\(timestampComponent(date, timeZone: timeZone)).jpg"
    }

    /// Collision-free variant: "name.mp4" → "name-2.mp4" → "name-3.mp4" …
    /// Two snapshots inside one second are entirely possible.
    public static func unique(_ filename: String, existing: Set<String>) -> String {
        guard existing.contains(filename) else { return filename }

        let (stem, ext) = splitExtension(filename)
        var n = 2
        // The bound is paranoia, not policy: one second's worth of snapshots can
        // never approach it, and an unbounded loop here would hang the writer queue.
        while n < 10_000 {
            let candidate = compose(stem: "\(stem)-\(n)", ext: ext)
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
        return compose(stem: "\(stem)-\(n)", ext: ext)
    }

    /// "0:00", "0:07", "1:23", "10:00", "1:02:33". Negative and NaN clamp to "0:00".
    /// Seconds are truncated, never rounded, so the label never shows a time the file
    /// has not reached.
    public static func elapsedLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 1 else { return "0:00" }
        // 99:59:59. Recording stops itself at 30 minutes, so this is only here so a
        // nonsense input cannot trap on the conversion to Int.
        let total = seconds >= 359_999 ? 359_999 : Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: Private

    /// Splits on the last "." only when it separates a non-empty stem from a
    /// non-empty extension, so "HelmMirror-2026-07-25-172000" (no dot) and
    /// oddities like "trailing." are left whole.
    private static func splitExtension(_ filename: String) -> (stem: String, ext: String) {
        guard let dot = filename.lastIndex(of: "."),
              dot != filename.startIndex,
              filename.index(after: dot) != filename.endIndex
        else { return (filename, "") }
        return (String(filename[filename.startIndex..<dot]),
                String(filename[filename.index(after: dot)...]))
    }

    private static func compose(stem: String, ext: String) -> String {
        ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}

// MARK: - Limits and guards

/// The thresholds requirement 6's guards are measured against.
public struct RecordingLimits: Equatable, Sendable {
    public var minimumFreeBytesToStart: Int64
    public var lowStorageStopBytes: Int64
    public var maxDuration: TimeInterval
    public var maxBytes: Int64

    public init(minimumFreeBytesToStart: Int64,
                lowStorageStopBytes: Int64,
                maxDuration: TimeInterval,
                maxBytes: Int64) {
        self.minimumFreeBytesToStart = minimumFreeBytesToStart
        self.lowStorageStopBytes = lowStorageStopBytes
        self.maxDuration = maxDuration
        self.maxBytes = maxBytes
    }

    /// The frozen helm profile:
    ///   start needs 500 MiB free   (≈ 33 min of headroom at 2 Mbit/s)
    ///   stop below 200 MiB free    (leaves the OS room to not start killing things)
    ///   stop at 30 minutes         (a helm clip, not a voyage log)
    ///   stop at 2 GiB              (Photos imports it quickly; MP4 stays well inside
    ///                               32-bit chunk offsets)
    public static let helm = RecordingLimits(minimumFreeBytesToStart: 524_288_000,
                                             lowStorageStopBytes: 209_715_200,
                                             maxDuration: 1800,
                                             maxBytes: 2_147_483_648)
}

/// Why `start()` refused. Nothing was changed and there is nothing to finalize.
public enum RecordingStartRefusal: Equatable, Sendable {
    case insufficientSpace(freeBytes: Int64, requiredBytes: Int64)

    /// "Only 499 MB free — need 500 MB". Integer MiB, no locale, no float formatting.
    public var message: String {
        switch self {
        case .insufficientSpace(let freeBytes, let requiredBytes):
            // Deliberately MiB labelled "MB": it matches how iOS Settings reports
            // free space, and integer division truncates so the number never rounds
            // up past a threshold the check itself just failed.
            return "Only \(RecordingByteScale.megabytes(freeBytes)) MB free"
                + " — need \(RecordingByteScale.megabytes(requiredBytes)) MB"
        }
    }
}

/// Why a recording ended. Every row of the robustness matrix (SPEC-RECORDING §10)
/// lands on exactly one of these.
public enum RecordingStopReason: Equatable, Sendable {
    case user               // the red button
    case videoEnded         // playback reached .ended or .failed
    case backgrounded       // UIApplication.didEnterBackgroundNotification
    case dismissed          // Back button, or the mirror view was dismantled
    case reachedMaxDuration
    case reachedMaxSize
    case lowStorage(freeBytes: Int64)
    case formatChanged
    case noKeyframe
    case writerFailed(String)

    /// True for everything except `.user`, `.videoEnded`, `.backgrounded`, `.dismissed`.
    public var isFailure: Bool {
        switch self {
        case .user, .videoEnded, .backgrounded, .dismissed:
            return false
        case .reachedMaxDuration, .reachedMaxSize, .lowStorage,
             .formatChanged, .noKeyframe, .writerFailed:
            return true
        }
    }

    /// Helm-readable, 1...60 characters, no jargon.
    public var message: String {
        switch self {
        case .user:               return "Recording stopped"
        case .videoEnded:         return "The video stopped"
        case .backgrounded:       return "HelmMirror moved to the background"
        case .dismissed:          return "Left the mirror screen"
        case .reachedMaxDuration: return "Reached the 30-minute limit"
        case .reachedMaxSize:     return "Reached the 2 GB size limit"
        case .lowStorage:         return "Storage almost full"
        case .formatChanged:      return "The video format changed"
        case .noKeyframe:         return "No usable video arrived"
        case .writerFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Recording failed" }
            // A writer error string is arbitrary length; the toast and the 110-char
            // diagnostics line both need it bounded.
            return RecordingByteScale.clamp("Recording failed: \(trimmed)", to: 60)
        }
    }
}

/// Requirement 6's guards, as two pure decisions.
public enum RecordingGuards {

    /// nil == clear to start.
    public static func canStart(freeBytes: Int64,
                                limits: RecordingLimits = .helm) -> RecordingStartRefusal? {
        // Exactly `minimumFreeBytesToStart` is allowed.
        guard freeBytes < limits.minimumFreeBytesToStart else { return nil }
        return .insufficientSpace(freeBytes: freeBytes,
                                  requiredBytes: limits.minimumFreeBytesToStart)
    }

    /// nil == keep going. Precedence, highest first: low storage, max size, max duration.
    /// Storage wins because it is the only one that can corrupt the write in progress.
    public static func stopReason(elapsed: TimeInterval,
                                  bytesWritten: Int64,
                                  freeBytes: Int64,
                                  limits: RecordingLimits = .helm) -> RecordingStopReason? {
        if freeBytes < limits.lowStorageStopBytes { return .lowStorage(freeBytes: freeBytes) }
        if bytesWritten >= limits.maxBytes { return .reachedMaxSize }
        if elapsed >= limits.maxDuration { return .reachedMaxDuration }
        return nil
    }
}

// MARK: - Small shared formatting

/// Locale-free helpers shared by the messages above. Not part of the frozen
/// interface — nothing outside this file should need them.
enum RecordingByteScale {
    static let bytesPerMegabyte: Int64 = 1_048_576

    /// Truncating MiB. Negative input clamps to 0 rather than printing "-1 MB".
    static func megabytes(_ bytes: Int64) -> Int64 {
        max(0, bytes) / bytesPerMegabyte
    }

    /// Character-count clamp with an ellipsis, so the result is exactly `limit`
    /// characters when it had to be cut.
    static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
