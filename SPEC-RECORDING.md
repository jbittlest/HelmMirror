# HelmMirror — Frozen Spec: Recording & Snapshots (v3.0)

Companion to `SPEC.md` (v1.0, wire protocol) and `SPEC-RTSP.md` (v2.0, native player).
Those two are unchanged by this document except where §9 says so, line by line.

**Status of the thing you are modifying:** the app works on real hardware. Full RTSP
handshake, 1280x720 H.264, live sonar on the phone, touches driving the plotter. Every
rule below exists to keep that true. If a choice here would risk the live path, the live
path wins.

---

## 0. The one idea

The plotter already sends H.264. So recording is a **passthrough mux**, not a capture:

```
RTSPVideoSession.onAccessUnit  ──▶  H264VideoView.enqueue      (display, unchanged, FIRST)
                               └─▶  MirrorCaptureController.append
                                      ├─▶ MirrorRecorder    → AVAssetWriterInput(outputSettings: nil) → .mp4
                                      └─▶ SnapshotCapture   → bounded GOP ring → VTDecompressionSession → JPEG
```

`outputSettings: nil` means AVAssetWriter writes the plotter's own AVCC bytes straight into
the MP4 sample table. Consequences, all of which are the point:

- **No re-encode.** Zero generational loss — the file is bit-identical video to what the MFD sent.
- **Negligible CPU and battery.** One `memcpy` per frame plus file I/O. This matters on a boat.
- **Small files.** ~2 Mbit/s ⇒ ~15 MB per minute, not ~150 MB.
- **The recording contains the plotter's picture only** — not HelmMirror's own overlay,
  not the record button, not the touch feedback. That is a feature (clean footage) and a
  limitation (the file has no on-screen recording indicator). Say so in any release note.

### Out of scope, deliberately

Audio of any kind (the plotter sends none; a mic track would need `AVAudioSession`, a
privacy string and a second writer input). Re-encoding, transcoding, resolution changes,
burned-in overlays or watermarks. HEVC. Live Photos. Rotation metadata. Trimming or any
in-app playback UI — the Photos app and the Files app are the player. Background recording
while the app is suspended (the RTSP session tears itself down on background; there is
nothing to record).

---

## 1. File map

### 1.1 New files

| File | Frameworks | Depends on |
|---|---|---|
| `Sources/RTSPCore/RecordingCore.swift` | **Foundation only** | — |
| `Sources/RTSP/H264SampleBuffer.swift` | CoreMedia | — |
| `Sources/Recording/MediaLibrary.swift` | Photos, UIKit | — |
| `Sources/Recording/MirrorRecorder.swift` | AVFoundation, CoreMedia, UIKit | RecordingCore, H264SampleBuffer |
| `Sources/Recording/SnapshotCapture.swift` | VideoToolbox, CoreMedia, ImageIO, AVFoundation | RecordingCore, H264SampleBuffer |
| `Sources/Recording/MirrorCaptureController.swift` | SwiftUI, AVFoundation | all of the above |
| `Sources/Recording/RecordingControls.swift` | SwiftUI, UIKit | MirrorCaptureController |

### 1.2 Modified files

| File | Change |
|---|---|
| `Sources/RTSP/H264VideoView.swift` | two private statics become thin forwarders to `H264SampleBuffer`. Public behaviour byte-identical. |
| `Sources/MirrorPlayerView.swift` | one new defaulted init parameter, one new stored property, two lines added inside `play(...)`, one line in `teardown()`. **The touch code is not touched.** |
| `Sources/ContentView.swift` | `MirrorScreen` only: one `@StateObject`, one overlay, three call sites. |
| `Verify/main.swift` | four new sections, ≥ 44 new vectors. |
| `project.yml` | three Info.plist keys. |
| `Package.swift` | one string added to an `exclude:` array. |

### 1.3 Build order

Each file below can be written and compiled independently in this order. Nothing later is
needed to compile anything earlier.

1. `Sources/RTSPCore/RecordingCore.swift` (§2)
2. `Verify/main.swift` additions (§8) — **run `swift run helmverify` here; it must be green before anything else is written**
3. `Sources/RTSP/H264SampleBuffer.swift` + the `H264VideoView` forwarders (§3)
4. `Sources/Recording/MediaLibrary.swift` (§6)
5. `Sources/Recording/MirrorRecorder.swift` (§4)
6. `Sources/Recording/SnapshotCapture.swift` (§5)
7. `Sources/Recording/MirrorCaptureController.swift` (§7.1)
8. `Sources/Recording/RecordingControls.swift` (§7.2)
9. `Sources/MirrorPlayerView.swift` edits (§9.1)
10. `Sources/ContentView.swift` edits (§9.2)
11. `project.yml` + `Package.swift` (§9.3, §9.4)

### 1.4 Hard rules, restated

- **No third-party dependencies. No CocoaPods.** Apple frameworks only.
- **Nothing in `Sources/RTSPCore/` may import** Network, CoreMedia, VideoToolbox,
  AVFoundation, Photos, ImageIO, UIKit or SwiftUI. That directory is compiled by
  `Package.swift` on a Mac with only Command Line Tools; an import breaks
  `swift run helmverify` for everyone.
- **`swift run helmverify` must stay green.** It is at 252 vectors today; after §8 it must
  print a strictly larger number and `PASS`.
- **The touch path in `MirrorVideoView` is frozen.** `touchesBegan/Moved/Ended/Cancelled`,
  `emit(_:event:down:)`, `trackId(for:)`, `nextFreeId()`, `releaseIds(for:)`,
  `contentRect()`, `clamp01(_:)` — do not edit a character of any of them.
- **No SwiftUI gesture modifier may ever be attached to `MirrorPlayerView`.** Not
  `.onTapGesture`, not `.gesture`, not `.simultaneousGesture`, not `.contentShape`.
  Every one of them steals touches from the plotter.

---

## 2. `Sources/RTSPCore/RecordingCore.swift` — the pure layer (frozen)

Foundation only. Value types and pure functions. No logging, no clocks, no file system,
no `DateFormatter`. Every declaration here is pinned by byte vectors in §8.

### 2.1 `RTPTimeline` — 90 kHz RTP timestamps → strictly monotonic media ticks

The RTP clock is 90 kHz, 32 bits, and wraps roughly every 13 hours 15 minutes. It can also
be restarted by the plotter. `AVAssetWriter` refuses a sample whose PTS is not strictly
greater than the previous one, so this type is the whole answer to requirement 2.

```swift
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
    public var ticks: Int64? { get }
    /// True for `.rejectedBackwards` and `.discontinuity`.
    public var isRejection: Bool { get }
}

public struct RTPTimeline: Equatable, Sendable {
    /// The RTP clock rate for H.264. Also the MP4 track's media timescale.
    public static let timescale: Int64 = 90_000
    /// 60 s at 90 kHz. Beyond this a forward delta is a clock discontinuity, not a gap:
    /// the RTSP session declares the stream `.ended` after 10 s of silence, so a real
    /// gap can never legitimately exceed a minute.
    public static let maxForwardJumpTicks: Int64 = 5_400_000

    /// -1 until the first accepted timestamp.
    public private(set) var lastEmittedTicks: Int64
    /// The most recent accepted non-zero inter-frame delta, in ticks. 0 until one exists.
    public private(set) var lastFrameDeltaTicks: Int64

    public init()
    public mutating func reset()

    /// Feed one access unit's `rtpTimestamp`.
    public mutating func push(_ rtpTimestamp: UInt32) -> RTPTimelineOutcome

    /// A defensible duration for the final sample, so `endSession(atSourceTime:)` does
    /// not truncate the last frame. `lastFrameDeltaTicks` clamped to 1500...9000
    /// (60 fps ... 10 fps); 3000 (30 fps) when no delta has been observed yet.
    public var nominalFrameDurationTicks: Int64 { get }
}
```

**`push` algorithm — frozen.**

```
if no origin yet:
    origin = ts;  last = ts;  lastEmittedTicks = 0;  lastFrameDeltaTicks = 0
    return .first(ticks: 0)

delta = Int64(Int32(bitPattern: ts &- last))     // signed 32-bit wrap-safe distance

if delta > maxForwardJumpTicks:  return .discontinuity(by: delta)      // no state change
if delta < 0:                    return .rejectedBackwards(by: -delta) // no state change

ticks = lastEmittedTicks + delta
if ticks <= lastEmittedTicks: ticks = lastEmittedTicks + 1             // delta == 0

last = ts
if delta > 0 { lastFrameDeltaTicks = delta }
lastEmittedTicks = ticks
return delta == 0 ? .coalesced(ticks: ticks) : .advanced(ticks: ticks)
```

`Int32(bitPattern: ts &- last)` is the entire wraparound story: the unsigned difference of
two 32-bit counters reinterpreted as signed gives the shortest signed distance, so
`0xFFFF_F000 → 0x0000_1000` is `+8192`, not `-4294959104`.

Rebasing to zero is implicit: `ticks` counts from the first accepted timestamp, so the
first written sample sits at exactly `CMTime(value: 0, timescale: 90_000)` and the writer's
`startSession(atSourceTime: .zero)` is exact.

### 2.2 `RecorderGate` — keyframe gating and end-of-file conditions

Requirement 1 in one type. Starting a passthrough file mid-GOP produces an MP4 whose first
sync sample is missing; it will not decode from the beginning in QuickTime, Photos or
anything else. We **skip**, never buffer — buffering would mean retaining access-unit data
before the user has even committed to a recording.

```swift
public enum RecorderGateEvent: Equatable, Sendable {
    case accessUnit(isKeyframe: Bool, isCorrupt: Bool)
    /// SPS/PPS bytes differ from the ones the open file's format description was built from.
    case parameterSetsChanged
    /// `AVAssetWriterInput.isReadyForMoreMediaData` was false.
    case writerBusy
    /// `RTPTimeline.push` returned a rejection.
    case timelineRejected
}

public enum RecorderGateDecision: Equatable, Sendable {
    /// Eligible. The caller MUST then call exactly one of `confirmWrite()`,
    /// `decide(.writerBusy)` or `decide(.timelineRejected)`.
    case write
    /// Drop this unit. `reason` is ≤ 24 chars and safe for the on-screen log.
    case skip(reason: String)
    /// Finalize the file cleanly and stop. Recording does NOT auto-restart.
    case finish(reason: String)
}

public struct RecorderGate: Equatable, Sendable {
    /// Give up waiting for the opening keyframe after this many skipped units
    /// (300 ≈ 10 s at 30 fps). Prevents a "recording" state that never makes a file.
    public static let maxSkipsBeforeFirstWrite = 300

    public private(set) var hasWritten: Bool      // false initially
    public private(set) var needsKeyframe: Bool   // true initially
    public private(set) var skipsSinceLastWrite: Int

    public init()
    public mutating func reset()
    public mutating func decide(_ event: RecorderGateEvent) -> RecorderGateDecision
    /// Call only after a `.write` decision was actually handed to the writer.
    public mutating func confirmWrite()
}
```

**Rules — frozen.**

| event | condition | mutation | decision |
|---|---|---|---|
| `.accessUnit` | `isCorrupt` | `needsKeyframe = true`, `skips += 1` | `.skip("corrupt frame")` |
| `.accessUnit` | `needsKeyframe && !isKeyframe && !hasWritten && skips + 1 > 300` | `skips += 1` | `.finish("no keyframe arrived")` |
| `.accessUnit` | `needsKeyframe && !isKeyframe && !hasWritten` | `skips += 1` | `.skip("waiting for keyframe")` |
| `.accessUnit` | `needsKeyframe && !isKeyframe && hasWritten` | `skips += 1` | `.skip("resyncing")` |
| `.accessUnit` | otherwise | none | `.write` |
| `.parameterSetsChanged` | `hasWritten` | none | `.finish("format changed")` |
| `.parameterSetsChanged` | `!hasWritten` | `needsKeyframe = true` | `.skip("format settling")` |
| `.writerBusy` | — | `needsKeyframe = true`, `skips += 1` | `.skip("writer busy")` |
| `.timelineRejected` | — | `needsKeyframe = true`, `skips += 1` | `.skip("timestamp out of order")` |

`confirmWrite()` sets `hasWritten = true`, `needsKeyframe = false`, `skipsSinceLastWrite = 0`.

**Why a parameter-set change ends the file.** A passthrough `AVAssetWriterInput` carries
exactly one `CMVideoFormatDescription` for the whole track; the SPS/PPS live in the `avcC`
box, written once. New SPS/PPS therefore cannot be expressed in the open file. The
alternatives are (a) end cleanly, (b) silently keep writing frames the file's `avcC` cannot
describe — which yields a file that decodes to garbage from that point. We end cleanly.
Recording does **not** auto-restart into a second file: two surprise files on a boat is
worse than one that stopped, and the diagnostic line says exactly why.

**Why a corrupt unit is skipped and forces a resync.** `H264AccessUnit.isCorrupt` means
packet loss was detected while the picture was assembled — some slices are missing.
Writing it puts an undecodable sample in the file and poisons every P-frame that
references it. Skipping it leaves a PTS gap, which MP4 expresses natively as a longer
sample duration. `RTSPVideoSession` already drops corrupt units before `onAccessUnit`
fires (`SPEC-RTSP` §5.4 step 5), so in practice this branch never runs — it is here so the
recorder is correct on its own terms rather than by inherited luck.

### 2.3 `RecordingNames` — deterministic filenames and labels

No `DateFormatter`: locale, calendar and 12/24-hour settings all leak into it, and a
filename that changes with the user's region is not vector-testable. `Calendar(identifier:
.gregorian)` with an explicit `timeZone` plus `String(format:)` is deterministic.

```swift
public enum RecordingNames {
    public static let prefix = "HelmMirror"

    /// "2026-07-25-172000" — sortable, no colons, no spaces, filesystem- and URL-safe.
    public static func timestampComponent(_ date: Date, timeZone: TimeZone) -> String

    /// "HelmMirror-2026-07-25-172000.mp4"
    public static func videoFilename(_ date: Date, timeZone: TimeZone) -> String
    /// "HelmMirror-2026-07-25-172013.jpg"
    public static func stillFilename(_ date: Date, timeZone: TimeZone) -> String

    /// Collision-free variant: "name.mp4" → "name-2.mp4" → "name-3.mp4" …
    /// Two snapshots inside one second are entirely possible.
    public static func unique(_ filename: String, existing: Set<String>) -> String

    /// "0:00", "0:07", "1:23", "10:00", "1:02:33". Negative and NaN clamp to "0:00".
    /// Seconds are truncated, never rounded, so the label never shows a time the file
    /// has not reached.
    public static func elapsedLabel(_ seconds: TimeInterval) -> String
}
```

`timestampComponent` is `String(format: "%04d-%02d-%02d-%02d%02d%02d", y, mo, d, h, mi, s)`
from `dateComponents([.year,.month,.day,.hour,.minute,.second], from: date)` on a
`Calendar(identifier: .gregorian)` whose `timeZone` is the argument.

Callers pass `TimeZone.current`. Vectors pass a fixed zone.

### 2.4 `RecordingLimits`, `RecordingGuards` — requirement 6's guards

```swift
public struct RecordingLimits: Equatable, Sendable {
    public var minimumFreeBytesToStart: Int64
    public var lowStorageStopBytes: Int64
    public var maxDuration: TimeInterval
    public var maxBytes: Int64

    public init(minimumFreeBytesToStart: Int64, lowStorageStopBytes: Int64,
                maxDuration: TimeInterval, maxBytes: Int64)

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

public enum RecordingStartRefusal: Equatable, Sendable {
    case insufficientSpace(freeBytes: Int64, requiredBytes: Int64)
    /// "Only 499 MB free — need 500 MB". Integer MiB, no locale, no float formatting.
    public var message: String { get }
}

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
    public var isFailure: Bool { get }
    /// Helm-readable, ≤ 60 characters, no jargon. e.g. "Storage almost full",
    /// "Reached the 30-minute limit", "The video format changed".
    public var message: String { get }
}

public enum RecordingGuards {
    /// nil == clear to start.
    public static func canStart(freeBytes: Int64,
                                limits: RecordingLimits = .helm) -> RecordingStartRefusal?

    /// nil == keep going. Precedence, highest first: low storage, max size, max duration.
    /// Storage wins because it is the only one that can corrupt the write in progress.
    public static func stopReason(elapsed: TimeInterval,
                                  bytesWritten: Int64,
                                  freeBytes: Int64,
                                  limits: RecordingLimits = .helm) -> RecordingStopReason?
}
```

Boundaries are frozen: `canStart` refuses when `freeBytes < minimumFreeBytesToStart`
(so exactly 500 MiB is allowed); `stopReason` fires `.lowStorage` when
`freeBytes < lowStorageStopBytes`, `.reachedMaxSize` when `bytesWritten >= maxBytes`,
`.reachedMaxDuration` when `elapsed >= maxDuration`.

---

## 3. `Sources/RTSP/H264SampleBuffer.swift` — factoring out what already works

`H264VideoView` already contains correct, hardware-proven code for building a
`CMVideoFormatDescription` from SPS/PPS and wrapping AVCC bytes in a `CMSampleBuffer`. The
recorder and the snapshot decoder need the same two things. **Move the bodies, do not
rewrite them.**

```swift
import Foundation
import CoreMedia

public enum H264SampleBuffer {

    /// Byte-for-byte the body of `H264VideoView.makeFormatDescription(sps:pps:)`.
    /// One contiguous copy of all SPS then all PPS, `nalUnitHeaderLength: 4`.
    public static func formatDescription(sps: [Data], pps: [Data]) -> CMVideoFormatDescription?

    /// Byte-for-byte the body of `H264VideoView.makeSampleBuffer(...)`, with two
    /// parameters lifted out of it:
    ///   - `presentationTime` replaces the hard-coded CMTime(rtpTimestamp, 90_000)
    ///   - `displayImmediately` gates the kCMSampleAttachmentKey_DisplayImmediately
    ///     attachment. The renderer wants it; a file must not have it.
    /// `kCMSampleAttachmentKey_NotSync` is still set whenever `isKeyframe == false` —
    /// that attachment is what populates the MP4 sync-sample table, so getting it wrong
    /// makes a file that cannot be scrubbed.
    public static func make(avcc: Data,
                            format: CMVideoFormatDescription,
                            isKeyframe: Bool,
                            presentationTime: CMTime,
                            duration: CMTime = .invalid,
                            displayImmediately: Bool) -> CMSampleBuffer?
}
```

`H264VideoView` then keeps its two private statics as one-line forwarders:

```swift
private static func makeFormatDescription(sps: [Data], pps: [Data]) -> CMVideoFormatDescription? {
    H264SampleBuffer.formatDescription(sps: sps, pps: pps)
}

private static func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription,
                                     isKeyframe: Bool, rtpTimestamp: UInt32) -> CMSampleBuffer? {
    H264SampleBuffer.make(avcc: avcc,
                          format: format,
                          isKeyframe: isKeyframe,
                          presentationTime: CMTime(value: CMTimeValue(rtpTimestamp), timescale: 90_000),
                          displayImmediately: true)
}
```

Nothing else in `H264VideoView` changes. Its public API, its threading, its diagnostics and
its behaviour are identical. **Verify this by building and running on the plotter before
writing §4** — a regression here is a regression in the live mirror.

---

## 4. `Sources/Recording/MirrorRecorder.swift`

### 4.1 Public interface

```swift
import Foundation
import AVFoundation
import CoreMedia
import UIKit

public final class MirrorRecorder {

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
    }

    /// Documents. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` make it
    /// visible in the Files app, which is the fallback when Photos access is refused.
    public static var defaultDirectory: URL { get }

    /// Free space at `url`'s volume, via `.volumeAvailableCapacityForImportantUsageKey`,
    /// falling back to `.volumeAvailableCapacityKey`. If neither is readable it returns
    /// `Int64.max` and logs `rec: free space unknown` — refusing the feature because a
    /// metadata read hiccuped would be worse than letting the writer report the error.
    public static func availableBytes(at url: URL) -> Int64

    public init(directory: URL = MirrorRecorder.defaultDirectory,
                limits: RecordingLimits = .helm)

    // All three are delivered on MAIN.
    public var onStateChanged: ((State) -> Void)?
    /// (elapsed, bytesWritten). ~2 Hz while recording, never while idle.
    public var onProgress: ((TimeInterval, Int64) -> Void)?
    /// `Result` is nil when no usable file was produced. Always fires exactly once per
    /// successful `start()`.
    public var onFinished: ((Result?, RecordingStopReason) -> Void)?

    /// Thread-safe, lock-free enough to be read from the video queue every frame.
    public var isActive: Bool { get }

    /// nil == armed. Non-nil == refused, nothing changed, nothing to finalize.
    @discardableResult
    public func start() -> RecordingStartRefusal?

    /// Idempotent. Safe from any thread. `onFinished` fires on main when the file is closed.
    public func stop(reason: RecordingStopReason)

    // ---- the tee. Both are called on the RTSP session's serial video queue. ----
    public func noteParameterSets(_ sets: H264ParameterSets)
    public func append(_ unit: H264AccessUnit)
}
```

### 4.2 Threading

Two queues and one lock.

- **Video queue** (owned by `RTSPVideoSession`, also owns the sockets). `append` runs here.
  It must never block: a stalled video queue stalls RTP intake and the live mirror
  freezes. What happens here is: one lock-guarded `Bool` read; if inactive, return. If
  active: the gate decision, the timeline push, one `H264SampleBuffer.make` (a `malloc`
  plus a `memcpy` of ~10–100 KB — microseconds, the same cost the display path already
  pays), then `writerQueue.async` with the retained `CMSampleBuffer`.
- **`writerQueue`** — `DispatchQueue(label: "com.jimmy.helmmirror.recorder")`, serial.
  Owns the `AVAssetWriter`, the `AVAssetWriterInput`, the byte counter and the guard timer.
  All file I/O lives here. Serial ⇒ sample order is preserved.
- **`stateLock`** — an `NSLock`, held only around plain field reads/writes, never across a
  CoreMedia or AVFoundation call. Guards `isActive` and the cached format description.

An uncontended `NSLock` is ~20 ns. At 30 fps the recorder's presence costs about
1.8 µs per second of wall clock when it is switched on, and nothing at all when it does
not exist (see §7.1: the recorder is created lazily on the first tap of the record button,
so before that the tee is a nil check on an `Optional` reference).

**Backpressure.** A counter, incremented before each `writerQueue.async` and decremented
inside it. If it exceeds **90** (3 s at 30 fps) the recorder stops itself with
`.writerFailed("writer backlog")`. Unbounded dispatch onto a slow filesystem is how a
recorder eats all the RAM on a device that is already low on storage.

**Swift 6 note.** `project.yml` currently sets `SWIFT_VERSION: "5.9"`, so Swift 5 language
mode. If the project later moves to Swift 6 strict concurrency, wrap the hand-off in
`private struct Sample: @unchecked Sendable { let buffer: CMSampleBuffer; let pts: CMTime }`
rather than loosening anything else.

### 4.3 `noteParameterSets`

On the video queue. Build `H264SampleBuffer.formatDescription(sps:pps:)`. Compare the
incoming `H264ParameterSets` with the stored one **by value** (`Equatable` on `[Data]`):

- identical → return, do nothing (the depacketizer already filters repeats, but the SDP
  path in `RTSPVideoSession.rtspClient(_:didPlay:)` can deliver the same sets a second
  time; belt and braces).
- different and `!isActive` → replace the cache.
- different and active → replace the cache, then feed `gate.decide(.parameterSetsChanged)`
  and act on it (§2.2): `.finish` ⇒ `stop(reason: .formatChanged)`; `.skip` ⇒ nothing more.

Refuse to build a format description from incomplete sets (`isComplete == false`) and log
`rec: err parameter sets incomplete`.

### 4.4 `append` — the per-frame path

```
1.  guard isActive                                       else { return }        // the whole cost when off
2.  guard let format = cachedFormatDescription           else { skip "no format"; return }
3.  switch gate.decide(.accessUnit(isKeyframe: unit.isKeyframe, isCorrupt: unit.isCorrupt))
       .skip(reason)   -> logSkip(reason); return
       .finish(reason) -> stop(reason: reason == "format changed" ? .formatChanged : .noKeyframe); return
       .write          -> continue
4.  switch timeline.push(unit.rtpTimestamp)
       rejection       -> gate.decide(.timelineRejected); logSkip(...); return
       ticks           -> continue
5.  sample = H264SampleBuffer.make(avcc: unit.avcc, format: format,
                                   isKeyframe: unit.isKeyframe,
                                   presentationTime: CMTime(value: ticks, timescale: 90_000),
                                   displayImmediately: false)
       nil             -> gate.decide(.writerBusy); logSkip("sample build failed"); return
6.  gate.confirmWrite()
7.  pending += 1; writerQueue.async { self.write(sample, isFirst: …, bytes: unit.avcc.count) }
```

**Requirement 7, precisely.** `unit.avcc` is a `Data` the depacketizer allocated for this
picture and never mutates afterwards. Step 5 copies its bytes into CoreMedia-owned memory
(`CMBlockBufferCreateWithMemoryBlock` + `CMBlockBufferReplaceDataBytes`, exactly as the
display path does) and the local `Data` goes out of scope at the end of `append`. **No
reference to `unit` or to `unit.avcc` outlives the call, and nothing about `unit` is
mutated.** There is no queue of pending `H264AccessUnit`s anywhere in this file. The gate
skips; it never buffers.

### 4.5 `write(_:isFirst:bytes:)` — on `writerQueue`

First sample only:

```swift
let name = RecordingNames.unique(RecordingNames.videoFilename(Date(), timeZone: .current),
                                 existing: existingNamesInDirectory())
let url = directory.appendingPathComponent(name)
try? FileManager.default.removeItem(at: url)          // AVAssetWriter refuses an existing file
writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = false            // no faststart rewrite pass on finalize
writer.movieFragmentInterval = CMTime(value: 5, timescale: 1)

input = AVAssetWriterInput(mediaType: .video,
                           outputSettings: nil,       // ← PASSTHROUGH. The whole spec.
                           sourceFormatHint: format)
input.expectsMediaDataInRealTime = true
input.mediaTimeScale = 90_000                         // exact 90 kHz PTS, no rounding
writer.add(input)
guard writer.startWriting() else { fail(writer.error) }
writer.startSession(atSourceTime: .zero)
```

`movieFragmentInterval` is not decoration. It makes AVAssetWriter flush a self-describing
fragment every 5 s, so if iOS kills the app mid-recording the file on disk is still a
playable prefix rather than a header-less carcass. That is requirement 6's "never leave a
corrupt/zero-byte file" for the one case the app cannot handle in code.

Every sample:

```swift
guard input.isReadyForMoreMediaData else {
    // Report back on the video queue's gate so the file resyncs at the next IDR.
    gateFeedWriterBusy()
    return
}
guard input.append(sample) else { fail(writer.error ?? …); return }
frames += 1; bytes += Int64(sampleBytes); lastPTS = pts
```

With `expectsMediaDataInRealTime = true` and passthrough, `isReadyForMoreMediaData` is
effectively always true; the branch exists because "effectively" is not "always" on a boat.

### 4.6 Finalizing

`stop(reason:)` is idempotent and safe from any thread. It sets `isActive = false`
immediately (so the video queue stops feeding within one frame), then on `writerQueue`:

```
if no writer:                onFinished(nil, reason) on main;   state = .idle;  return
state = .finishing
cancel the guard timer
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: lastPTS.value + timeline.nominalFrameDurationTicks,
                                       timescale: 90_000))
writer.finishWriting { … }
```

Inside the completion:

- `writer.status == .completed` **and** `frames >= 2` **and** file size > 0 →
  `Result(url:duration:bytes:frames:)`, where `duration = Double(lastPTS.value) / 90_000`.
- otherwise → **delete the file** and report `nil` with
  `.writerFailed(writer.error?.localizedDescription ?? "empty file")`. A one-frame or
  zero-byte MP4 in the user's Documents is litter that looks like a bug.

A `UIApplication.beginBackgroundTask` is taken for the duration of `finishWriting` and
ended in the completion — without it, a stop triggered by backgrounding is killed
mid-flush and produces exactly the corrupt file this rule forbids.

### 4.7 The guard timer

A `DispatchSourceTimer` on `writerQueue`, 1 Hz while recording:

- every tick: `onProgress(elapsed, bytes)` on main at 2 Hz (so the label counts smoothly),
  and evaluate `RecordingGuards.stopReason(elapsed:bytesWritten:freeBytes:)`.
- `freeBytes` is re-read from the volume every **5th** tick only — the resource-value read
  is cheap but not free, and 5 s of granularity against a 200 MiB floor is ample.
- a non-nil `stopReason` ⇒ `stop(reason:)`.

### 4.8 Lifecycle hooks the recorder owns itself

`UIApplication.didEnterBackgroundNotification` → `stop(reason: .backgrounded)`.
Registered in `init`, removed in `deinit`. `RTSPVideoSession` observes the same
notification to tear down its sockets; the two are independent — the recorder only
finalizes what it already has, so notification ordering does not matter.

Everything else (Back, dismantle, video ended) is driven by `MirrorCaptureController` (§7.1).

### 4.9 Diagnostics vocabulary

Every line goes through `MirrorDiagnostics.shared.log`, is prefixed `rec:` so it is
greppable in the 40-line ring, and is ≤ 110 characters (`SPEC` §11).

```
rec: armed — waiting for keyframe
rec: start HelmMirror-2026-07-25-172000.mp4
rec: skip <reason> (<n> since last write)      ← rate-limited to one line per second
rec: stop — <RecordingStopReason.message>
rec: wrote <frames> frames, <elapsedLabel>, <n> MB
rec: err <detail>
rec: free space unknown
```

**Never log per-frame.** The ring is 40 lines and shared with the RTSP handshake.

---

## 5. `Sources/Recording/SnapshotCapture.swift`

### 5.1 Why not the obvious things

- `UIView.drawHierarchy(in:afterScreenUpdates:)` and `UIGraphicsImageRenderer` do not
  capture an `AVSampleBufferDisplayLayer`. The layer's content is composited by the
  render server, not by Core Animation's software path; you get a black rectangle. This is
  the single most common wrong answer and it fails silently.
- `AVSampleBufferDisplayLayer` has no `copyDisplayedPixelBuffer`. The SDK on this machine
  puts it on `AVSampleBufferVideoRenderer` — **iOS 17.4+** — and it is documented to
  return NULL when the image is protected, when nothing is displayed, or "if the rate is
  non-zero". The deployment target is iOS 16. So it is a fast path, never the mechanism.
- Retaining "the last `CMSampleBuffer`" and decoding it alone does not work: a P-frame is
  meaningless without its reference chain back to the last IDR.

### 5.2 The mechanism: a bounded GOP ring plus an on-demand decode

Keep, in AVCC form, **the current group of pictures**: cleared and restarted at every
keyframe, appended to for every unit after it. Decoding that ring end-to-end through a
`VTDecompressionSession` reproduces exactly the frame the user is looking at, because the
last unit in the ring is the last unit the display layer was handed.

Cost while armed: one array append and one integer add per frame; ≤ 8 MiB retained (the
plotter's GOP at 1280x720 / ~2 Mbit/s is well under 1 MiB). Cost while not armed: nothing —
the ring is empty and there is no `VTDecompressionSession` in existence. Nothing is ever
mutated: `Data` values are appended to an array and read back.

This is a real, stated tradeoff against requirement 7's "must not retain": snapshots
cannot work without retaining *something*, so the retention is bounded, append-only,
armed only while the mirror screen is on screen, and dropped the instant it leaves.

```swift
import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import ImageIO
import UIKit

public final class SnapshotCapture {

    public struct Result: Equatable, Sendable {
        public let url: URL
        public let pixelSize: CGSize
    }

    public enum Failure: Error, Equatable {
        case notArmed
        case noFrame                 // nothing decodable yet — no keyframe has arrived
        case decodeFailed(OSStatus)
        case encodeFailed
        case writeFailed(String)
        /// Helm-readable, ≤ 60 chars.
        public var message: String { get }
    }

    /// Frozen caps. On overflow the ring FREEZES (keeps what it has, stops appending)
    /// until the next keyframe clears it — truncating the middle of a GOP would break
    /// the reference chain and decode to garbage.
    public static let maxGOPFrames = 300
    public static let maxGOPBytes  = 8 << 20

    public init(directory: URL = MirrorRecorder.defaultDirectory)

    /// Maintain the ring. Set from MAIN; read on the video queue under a lock.
    /// Setting it to false clears the ring and tears down any VTDecompressionSession.
    public var isArmed: Bool { get set }

    /// Weak. Used only for the iOS 17.4+ fast path. Never retained.
    public weak var displayLayer: AVSampleBufferDisplayLayer?

    // ---- the tee. Both on the RTSP session's serial video queue. ----
    public func noteParameterSets(_ sets: H264ParameterSets)
    public func append(_ unit: H264AccessUnit)

    /// Completion on MAIN.
    public func capture(completion: @escaping (Swift.Result<Result, Failure>) -> Void)
}
```

### 5.3 `append`

```
guard isArmed, !unit.isCorrupt          else { return }
if unit.isKeyframe { ring = []; ringBytes = 0; frozen = false }
guard !ring.isEmpty || unit.isKeyframe  else { return }      // never start mid-GOP
guard !frozen                           else { return }
if ring.count + 1 > maxGOPFrames || ringBytes + unit.avcc.count > maxGOPBytes {
    frozen = true; logOnce("snap: gop ring full"); return
}
ring.append((avcc: unit.avcc, ticks: <RTPTimeline-independent ordering key>, isKeyframe: unit.isKeyframe))
ringBytes += unit.avcc.count
```

The ordering key is a monotonically increasing `Int64` the ring maintains itself
(`index * 3000`, in the 90 kHz timescale) — a synthetic, strictly increasing PTS. The
snapshot path does not care about real time, only about decode order and about which
decoded frame is last. Using a private counter rather than `RTPTimeline` keeps the two
features independent: a snapshot must work whether or not a recording is in progress.

### 5.4 `capture(completion:)`

Runs its work on a private serial `decodeQueue`; the completion is hopped to main.

1. **Fast path (iOS 17.4+).** `if #available(iOS 17.4, *)`, on main, try
   `displayLayer?.sampleBufferRenderer.copyDisplayedPixelBuffer()`. Non-nil ⇒ go to step 4.
   Nil ⇒ fall through silently (no diagnostic; this is expected on many frames).
2. **Ring path.** Snapshot the ring under the lock (a value copy of the array — the
   `Data` elements are shared COW buffers, so this is cheap and the video queue is never
   blocked). If empty or it holds no keyframe ⇒ `.failure(.noFrame)`.
3. Create a `VTDecompressionSession` from the cached `CMVideoFormatDescription` with
   `kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA` and
   `kCVPixelBufferIOSurfacePropertiesKey: [:]` (32BGRA is what
   `VTCreateCGImageFromCVPixelBuffer` handles without surprises). Feed every ring entry in
   order as a `H264SampleBuffer.make(..., displayImmediately: false)` sample, then
   `VTDecompressionSessionWaitForAsynchronousFrames`. Keep the emitted `CVPixelBuffer`
   with the **greatest** PTS, not the last one emitted — decode order and display order are
   the same on this stream today, but a stream with B-frames would silently give the wrong
   frame. Invalidate the session before returning.
4. **Encode.** `VTCreateCGImageFromCVPixelBuffer` → `CGImage`; `CGImageDestination`
   with `UTType.jpeg.identifier` and `kCGImageDestinationLossyCompressionQuality: 0.9`,
   written straight to
   `directory/RecordingNames.unique(RecordingNames.stillFilename(Date(), timeZone: .current), existing:)`.
   A file (not a `UIImage`) so the Photos save and the share-sheet fallback are exactly the
   same code as for video, and so the still is visible in the Files app too.
5. `.success(Result(url:pixelSize:))`.

Typical cost: the fast path is sub-millisecond; the ring path decodes ≤ 60 frames of
720p through the hardware decoder, tens of milliseconds. Both are imperceptible.

Diagnostics: `snap: HelmMirror-2026-07-25-172013.jpg (1280x720)` on success,
`snap: err <detail>` on failure. One line per attempt, never per frame.

---

## 6. `Sources/Recording/MediaLibrary.swift`

**Add-only, always.** `NSPhotoLibraryAddUsageDescription` and `PHAccessLevel.addOnly` and
nothing else. HelmMirror has no business reading the user's photos, and requesting
read access would show a scarier prompt for no gain.

```swift
import Foundation
import Photos
import UIKit

public enum MediaLibrary {

    public enum SaveOutcome: Equatable, Sendable {
        case saved
        case permissionDenied
        case failed(String)
    }

    /// `PHPhotoLibrary.authorizationStatus(for: .addOnly)`.
    public static var addOnlyStatus: PHAuthorizationStatus { get }

    /// `PHPhotoLibrary.requestAuthorization(for: .addOnly)`. Completion on MAIN.
    /// Callers must check `addOnlyStatus` first and NOT call this when it is
    /// `.denied` or `.restricted` — iOS will not re-present the prompt, so calling it
    /// again just produces a silent no.
    public static func requestAddOnlyAuthorization(_ completion: @escaping (PHAuthorizationStatus) -> Void)

    /// `PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest
    ///   .creationRequestForAssetFromVideo(atFileURL: url) }`. Completion on MAIN.
    public static func saveVideo(at url: URL, completion: @escaping (SaveOutcome) -> Void)

    /// `PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options:)`
    /// with `shouldMoveFile = false`. Completion on MAIN.
    public static func savePhoto(at url: URL, completion: @escaping (SaveOutcome) -> Void)
}
```

Rules:

- `performChanges`' completion arrives on an arbitrary queue. Always hop to main.
- **The Documents copy is never deleted**, on success or failure. Requirement 3: the file
  must remain retrievable. Photos gets a copy (`shouldMoveFile = false`); Files keeps the
  original.
- A `.denied`/`.restricted` status is not an error to retry. It is a fact: report
  `.permissionDenied`, keep the file, offer the share sheet.
- No `PHPhotoLibraryChangeObserver`, no album creation, no `PHAssetCollection`. Saving
  into the camera roll is the whole feature.

---

## 7. UI

### 7.1 `Sources/Recording/MirrorCaptureController.swift`

The single object SwiftUI binds to and the UIView tees into. It owns the recorder and the
snapshot capture and is the only place the two features know about each other.

```swift
import SwiftUI
import AVFoundation

public struct CaptureToast: Equatable, Identifiable {
    public let id: UUID
    public let text: String        // ≤ 60 chars
    public let symbol: String      // SF Symbol
    public let isError: Bool
    /// Non-nil ⇒ the toast is tappable and presents a share sheet for this file.
    public let shareURL: URL?
}

@MainActor
public final class MirrorCaptureController: ObservableObject {

    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var recordedBytes: Int64 = 0
    @Published public private(set) var freeBytes: Int64 = 0
    @Published public private(set) var controlsVisible: Bool = true
    /// Drives the 150 ms white shutter flash. Always `allowsHitTesting(false)`.
    @Published public private(set) var flash: Bool = false
    @Published public private(set) var toast: CaptureToast?

    public init()

    // ---- user actions, all on MAIN ----
    public func toggleRecording()
    public func takeSnapshot()
    /// Show the bar and restart the auto-hide timer. Called by every control.
    public func revealControls()

    // ---- lifecycle, all on MAIN ----
    /// The mirror screen appeared: arms the snapshot ring, refreshes `freeBytes`.
    public func viewAppeared()
    /// Back, onDisappear, or dismantleUIView. Stops recording, disarms the ring.
    /// Idempotent.
    public func stopEverything(reason: RecordingStopReason)
    /// Playback reached `.ended` or `.failed`.
    public func videoStopped()

    // ---- wiring for MirrorVideoView. Safe from the video queue. ----
    public nonisolated func attach(displayLayer: AVSampleBufferDisplayLayer)
    public nonisolated func noteParameterSets(_ sets: H264ParameterSets)
    public nonisolated func append(_ unit: H264AccessUnit)
}
```

Behaviour:

- **`MirrorRecorder` is created lazily**, on the first `toggleRecording()`. Until then
  `append` forwards only to `SnapshotCapture`, and the recorder does not exist. This is
  requirement 7 taken literally: recording is off by default and costs nothing.
- `toggleRecording()` while stopped: refresh `freeBytes`, call `recorder.start()`. A
  non-nil `RecordingStartRefusal` ⇒ toast `refusal.message` (error styling), log
  `rec: err <message>`, stay stopped. Otherwise `isRecording = true`, pin the bar visible.
- `toggleRecording()` while recording: `recorder.stop(reason: .user)`.
- `onFinished(result, reason)`:
  - `reason.isFailure` ⇒ toast `reason.message` with error styling.
  - `result == nil` ⇒ toast, no save attempt.
  - `result != nil` ⇒ §7.3 save flow, then a toast that reports where it went.
- `takeSnapshot()`: fire `flash` for 150 ms immediately (the shutter must feel instant),
  then `SnapshotCapture.capture`. Success ⇒ §7.3 save flow. Failure ⇒ toast
  `failure.message`.
- **Auto-hide.** `controlsVisible` starts true; a `Task` sleeps
  `RecordingControlsPlacement.autoHideDelay` (4.0 s) and sets it false. `revealControls()`
  cancels and restarts that task. While `isRecording` the bar does **not** auto-hide —
  you must be able to see the elapsed time and reach the stop button.
- `elapsed`/`recordedBytes` come from `onProgress` at 2 Hz. `freeBytes` is refreshed on
  `viewAppeared()` and whenever `controlsVisible` becomes true.
- Toast lifetime: 4 s when it carries a `shareURL`, 2 s otherwise. A new toast replaces
  the old one.

### 7.2 `Sources/Recording/RecordingControls.swift`

```swift
public enum RecordingControlsPlacement {
    /// Bottom-leading, mirroring the existing top-leading Back button. One named
    /// constant so it is a one-line change if it ever collides with the plotter's
    /// own on-screen furniture in the field.
    public static let alignment: Alignment = .bottomLeading
    public static let inset: CGFloat = 12
    /// The invisible reveal target when the bar is hidden and not recording.
    public static let hiddenTapTarget = CGSize(width: 88, height: 56)
    public static let autoHideDelay: TimeInterval = 4.0
}

public struct RecordingControlsBar: View {
    public init(capture: MirrorCaptureController)
    public var body: some View
}

/// Share-sheet fallback. On iPad `popoverPresentationController.sourceView` and
/// `sourceRect` MUST be set or it crashes — TARGETED_DEVICE_FAMILY is "1,2".
public struct ShareSheet: UIViewControllerRepresentable {
    public init(url: URL)
}
```

**The touch contract — this is the part that can break the product.**

`MirrorVideoView` receives touches only where SwiftUI does not hit-test something above it.
Therefore:

- The bar's root **must** `.fixedSize()` and must contain **no** `Spacer()` and **no**
  `.frame(maxWidth: .infinity)` / `.frame(maxHeight: .infinity)`. It is sized to its
  content, and it is attached with `.overlay(alignment:)`, which does not expand it.
- The white shutter flash and the toast are `.allowsHitTesting(false)`.
- No gesture modifier, no `.contentShape`, is attached anywhere that covers the video.
- Three visual states, all in the same corner:
  - **expanded** (`controlsVisible`): a capsule of `.ultraThinMaterial`, ~230 × 60 pt.
  - **hidden, recording**: a compact pill, `● 0:07`, ~96 × 40 pt, which is also the reveal
    target.
  - **hidden, not recording**: `Color.clear.frame(88 × 56).contentShape(Rectangle())` —
    invisible, and the reveal target.
- **The dead zone is therefore 88 × 56 pt plus a 12 pt inset in the bottom-leading corner
  when hidden, and up to ~230 × 60 pt when expanded.** Touches there reveal or operate the
  bar and are not forwarded to the plotter. Everything else on the surface is a plotter
  touch target, exactly as today. This cost is unavoidable and is stated here so nobody
  "fixes" it later by widening the overlay.
- Buttons call `capture.revealControls()` in addition to their own action, so operating
  one resets the auto-hide timer. Do **not** put `.onTapGesture` on a container that also
  holds buttons — SwiftUI's resolution between the two is not something to rely on.

Expanded bar content, leading to trailing:

1. **Record button.** 44 × 44 tap target, `.contentShape(Circle())`.
   Idle: a 22 pt red `Circle`. Recording: an 18 pt red `RoundedRectangle(cornerRadius: 4)`.
   Accessibility label "Start recording" / "Stop recording".
2. **Middle.**
   Recording: a 8 pt red dot that pulses (`.easeInOut(duration: 0.7).repeatForever(autoreverses: true)`
   between opacity 1.0 and 0.35 — **only the dot**, so the stop button never fades under a
   moving boat) plus `Text(RecordingNames.elapsedLabel(capture.elapsed)).monospacedDigit()`.
   Idle: `Text(freeSpaceLabel).font(.caption2)`, from
   `ByteCountFormatter(countStyle: .file)` — this is requirement 6's "show the free-space
   check before starting". Tinted amber when `freeBytes < RecordingLimits.helm.minimumFreeBytesToStart`.
3. **Snapshot button.** 44 × 44, `Image(systemName: "camera.fill")`. Accessibility label
   "Take snapshot".

### 7.3 The save flow (identical for video and stills)

```
status = MediaLibrary.addOnlyStatus
switch status
  .authorized, .limited  -> save; on .saved  -> toast "Saved to Photos"      (symbol checkmark)
                                 on .failed  -> toast "Saved to Files"       + shareURL
  .notDetermined         -> requestAddOnlyAuthorization; granted -> as above
                                                          denied -> toast "Saved to Files" + shareURL
  .denied, .restricted   -> do NOT re-request.
                            toast "Saved to Files — Photos access is off"    + shareURL
```

The toast carrying a `shareURL` is tappable and presents `ShareSheet`. **Nothing is
auto-presented**: a modal sheet that appears by itself over a live helm display is the
wrong behaviour on a boat. The user opts in by tapping.

The corresponding diagnostic lines: `rec: photos saved`, `rec: photos denied — kept in Files`,
`rec: photos err <detail>` (and `snap:` equivalents).

---

## 8. `Verify/main.swift` — new byte vectors

Everything vectored below is in `Sources/RTSPCore/RecordingCore.swift` and imports nothing
but Foundation, so `swift run helmverify` keeps working on a Mac with only Command Line
Tools. **No AVFoundation, VideoToolbox, Photos, ImageIO, CoreMedia or UIKit type may
appear in a vector.**

The harness is at **252 vectors** today. The four sections below add **at least 44**;
`swift run helmverify` must print a strictly larger total and `PASS`.

### 8.1 `section("Recording — RTP timeline")`

| # | vector | expected |
|---|---|---|
| 1 | `push(9000)` on a fresh timeline | `.first(ticks: 0)` |
| 2 | then `push(12000)` | `.advanced(ticks: 3000)` |
| 3 | then `push(15000)` | `.advanced(ticks: 6000)` |
| 4 | `lastFrameDeltaTicks` after 3 | `3000` |
| 5 | wraparound: origin `0xFFFF_F000`, then `push(0x0000_1000)` | `.advanced(ticks: 8192)` |
| 6 | wraparound at the exact boundary: origin `0xFFFF_FFFF`, then `push(0)` | `.advanced(ticks: 1)` |
| 7 | duplicate: origin `9000`, `push(9000)` | `.coalesced(ticks: 1)` |
| 8 | duplicate after progress: `9000, 12000, 12000` | third is `.coalesced(ticks: 3001)` |
| 9 | then `push(15000)` after the coalesce | `.advanced(ticks: 6001)` — strictly monotonic |
| 10 | backwards: `9000` then `push(6000)` | `.rejectedBackwards(by: 3000)` |
| 11 | timeline state after 10 is unchanged | `lastEmittedTicks == 0` |
| 12 | a valid push after a rejection still works | `push(12000)` → `.advanced(ticks: 3000)` |
| 13 | discontinuity: `0` then `push(5_400_001)` | `.discontinuity(by: 5_400_001)` |
| 14 | just inside the limit: `0` then `push(5_400_000)` | `.advanced(ticks: 5_400_000)` |
| 15 | state unchanged after 13 | `lastEmittedTicks == 0` |
| 16 | 500 pushes of `+3000` starting at `0xFFFF_0000` | every outcome accepted, ticks strictly increasing, final `1_497_000` |
| 17 | `nominalFrameDurationTicks` on a fresh timeline | `3000` |
| 18 | after a `+1000` delta (clamp low) | `1500` |
| 19 | after a `+20000` delta (clamp high) | `9000` |
| 20 | `reset()` then `push(7)` | `.first(ticks: 0)` |

### 8.2 `section("Recording — keyframe gate")`

| # | vector | expected |
|---|---|---|
| 21 | fresh gate, non-keyframe | `.skip("waiting for keyframe")` |
| 22 | fresh gate, corrupt keyframe | `.skip("corrupt frame")` |
| 23 | fresh gate, clean keyframe | `.write` |
| 24 | `confirmWrite()` then a clean non-keyframe | `.write` |
| 25 | mid-recording corrupt unit | `.skip("corrupt frame")` |
| 26 | the next clean non-keyframe after 25 | `.skip("resyncing")` |
| 27 | the next clean keyframe after 26 | `.write` |
| 28 | `.writerBusy` mid-recording, then a non-keyframe | `.skip("writer busy")`, then `.skip("resyncing")` |
| 29 | `.timelineRejected` mid-recording, then a keyframe | `.skip("timestamp out of order")`, then `.write` |
| 30 | `.parameterSetsChanged` after `confirmWrite()` | `.finish("format changed")` |
| 31 | `.parameterSetsChanged` before any write | `.skip("format settling")` |
| 32 | 300 non-keyframes on a fresh gate | the 300th is `.skip`, the 301st is `.finish("no keyframe arrived")` |
| 33 | `skipsSinceLastWrite` resets on `confirmWrite()` | `0` |
| 34 | `hasWritten` stays false until `confirmWrite()` even after a `.write` decision | `false` |
| 35 | `reset()` returns the gate to `hasWritten == false, needsKeyframe == true` | true |

### 8.3 `section("Recording — filenames")`

Fixed instant: `Date(timeIntervalSince1970: 1_785_000_000)` = **2026-07-25T17:20:00Z**.

| # | vector | expected |
|---|---|---|
| 36 | `timestampComponent(fixed, timeZone: UTC)` | `"2026-07-25-172000"` |
| 37 | `videoFilename(fixed, timeZone: UTC)` | `"HelmMirror-2026-07-25-172000.mp4"` |
| 38 | `stillFilename(fixed, timeZone: UTC)` | `"HelmMirror-2026-07-25-172000.jpg"` |
| 39 | `timestampComponent(fixed, timeZone: secondsFromGMT: -14400)` | `"2026-07-25-132000"` |
| 40 | `unique(name, existing: [name])` | `"HelmMirror-2026-07-25-172000-2.mp4"` |
| 41 | `unique(name, existing: [name, name-2])` | `"…-3.mp4"` |
| 42 | `unique(name, existing: [])` | unchanged |
| 43 | no filename contains `/ \ : * ? " < > \|` or a space | true |
| 44 | `elapsedLabel` for `0, 7, 59, 60, 83, 599, 600, 3599, 3600, 3753` | `"0:00","0:07","0:59","1:00","1:23","9:59","10:00","59:59","1:00:00","1:02:33"` |
| 45 | `elapsedLabel(-5)` and `elapsedLabel(0.9)` | `"0:00"` both |

### 8.4 `section("Recording — guards")`

| # | vector | expected |
|---|---|---|
| 46 | `canStart(freeBytes: 524_288_000)` | `nil` (exactly 500 MiB is allowed) |
| 47 | `canStart(freeBytes: 524_287_999)` | `.insufficientSpace(524_287_999, 524_288_000)` |
| 48 | that refusal's `message` | `"Only 499 MB free — need 500 MB"` |
| 49 | `stopReason(elapsed: 1799, bytes: 1_000, free: 10 GiB)` | `nil` |
| 50 | `stopReason(elapsed: 1800, bytes: 1_000, free: 10 GiB)` | `.reachedMaxDuration` |
| 51 | `stopReason(elapsed: 1, bytes: 2_147_483_648, free: 10 GiB)` | `.reachedMaxSize` |
| 52 | `stopReason(elapsed: 1, bytes: 1, free: 209_715_200)` | `nil` (boundary) |
| 53 | `stopReason(elapsed: 1, bytes: 1, free: 209_715_199)` | `.lowStorage(209_715_199)` |
| 54 | precedence: `elapsed 3600, bytes 3 GiB, free 100 MiB` | `.lowStorage` |
| 55 | precedence: `elapsed 3600, bytes 3 GiB, free 10 GiB` | `.reachedMaxSize` |
| 56 | `isFailure` for `.user, .videoEnded, .backgrounded, .dismissed` | all `false` |
| 57 | `isFailure` for `.reachedMaxDuration, .reachedMaxSize, .lowStorage, .formatChanged, .noKeyframe, .writerFailed` | all `true` |
| 58 | every `RecordingStopReason.message` is 1...60 characters | true |
| 59 | every `RecorderGateDecision` reason string is ≤ 24 characters | true |

---

## 9. Exact edits to existing files

### 9.1 `Sources/MirrorPlayerView.swift`

**Four edits. The touch code is not one of them.**

**(a)** `MirrorPlayerView` gains one stored property and one defaulted init parameter.
Placing it before `onTouch:` keeps every existing labelled call site source-compatible,
and the default `nil` keeps the behaviour of any caller that does not pass it identical to
today's:

```swift
public let capture: MirrorCaptureController?

public init(rtspURL: String,
            useTCP: Bool = false,
            videoAspect: CGFloat = 1280.0 / 720.0,
            capture: MirrorCaptureController? = nil,          // ← new
            onTouch: @escaping ([HelmTouchPoint]) -> Void,
            onState: @escaping (MirrorPlaybackState) -> Void = { _ in })
```

**(b)** `makeUIView` and `updateUIView` each gain one line, placed with the other live
values and **before** `view.play(...)`:

```swift
view.capture = capture
```

**(c)** `MirrorVideoView` gains a lock-guarded property. The lock exists because SwiftUI
writes it on main while the video queue reads it every frame; an uncontended `NSLock` is
~20 ns, i.e. ~1.8 µs per second at 30 fps.

```swift
private let captureLock = NSLock()
private var _capture: MirrorCaptureController?
var capture: MirrorCaptureController? {
    get { captureLock.lock(); defer { captureLock.unlock() }; return _capture }
    set {
        captureLock.lock(); _capture = newValue; captureLock.unlock()
        newValue?.attach(displayLayer: displayLayer)
    }
}
```

**(d)** Inside `play(urlString:useTCP:)`, the two existing session callbacks gain one line
each. **The tee runs AFTER the display call, always.** The mirror's latency is the product;
nothing may be inserted ahead of `enqueue`.

```swift
session.onParameterSets = { [weak self] ps in
    guard let self else { return }
    self.setParameterSets(sps: ps.sps, pps: ps.pps)
    self.capture?.noteParameterSets(ps)          // ← new, after the display path
}
session.onAccessUnit = { [weak self] au in
    guard let self else { return }
    self.enqueue(accessUnit: au.avcc,
                 isKeyframe: au.isKeyframe,
                 rtpTimestamp: au.rtpTimestamp)
    self.capture?.append(au)                     // ← new, after the display path
}
```

**(e)** `teardown()` gains two lines, before the existing body:

```swift
let c = capture
capture = nil
DispatchQueue.main.async { c?.stopEverything(reason: .dismissed) }
```

`teardown()` is called from `dismantleUIView`, which runs on main; the hop is there
because `stopEverything` is `@MainActor` and `teardown` is not annotated.

Nothing else in this file changes. `MirrorDiagnostics`, `MirrorPlaybackState`,
`MirrorAttempt`, `contentRect()`, the track-id bookkeeping and every `touches*` override
stay byte-identical.

### 9.2 `Sources/ContentView.swift` — `MirrorScreen` only

**(a)** One new state object:

```swift
@StateObject private var capture = MirrorCaptureController()
```

**(b)** Pass it to the player and stop recording when playback dies. Inside the existing
`MirrorPlayerView(...)` call:

```swift
MirrorPlayerView(rtspURL: attempt.url,
                 useTCP: attempt.useTCP,
                 capture: capture,                        // ← new
                 onTouch: onTouch) { state in
    playback = state
    if state.isPlaying { everPlayed = true; timedOut = false }
    if state == .failed || state == .ended {
        capture.videoStopped()                            // ← new
        nextAttempt()
    }
}
```

`.stalled` deliberately does **not** stop a recording: the RTSP session gives a stall 10 s
to recover, and MP4 expresses the gap as a longer sample duration. Losing a file to a
5-second Wi-Fi hiccup at the helm would be worse than a file with a pause in it.

**(c)** The overlay, immediately after the existing `.overlay(alignment: .topLeading)` for
the Back button and before `.task(id: attempt)`:

```swift
.overlay(alignment: RecordingControlsPlacement.alignment) {
    RecordingControlsBar(capture: capture)
}
```

**(d)** The Back button's action becomes:

```swift
Button {
    capture.stopEverything(reason: .dismissed)
    onBack()
} label: { … }
```

**(e)** Two lifecycle modifiers alongside `.task(id: attempt)`:

```swift
.onAppear { capture.viewAppeared() }
.onDisappear { capture.stopEverything(reason: .dismissed) }
```

The status overlay, the attempt ladder, the diagnostics view and the aspect ratio are
untouched. Note that the controls bar is drawn under the failure overlay whenever
`showOverlay` is true, which is correct: there is nothing to record when there is no video.

### 9.3 `project.yml`

Three keys under `targets.HelmMirror.info.properties`, alongside the existing ones:

```yaml
        # --- Photo library: ADD-ONLY. Never add NSPhotoLibraryUsageDescription;
        #     HelmMirror has no reason to read the user's photos and asking for
        #     read access shows a much scarier prompt for no gain.
        NSPhotoLibraryAddUsageDescription: >-
          HelmMirror saves the recordings and screenshots you take of the
          chartplotter into your photo library.
        # --- Recordings are visible and copyable in the Files app, which is the
        #     fallback whenever photo-library access is refused.
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
```

No new build settings. No new frameworks to link — AVFoundation, VideoToolbox, Photos,
ImageIO and CoreMedia are all autolinked from `import`.

### 9.4 `Package.swift`

`Sources/Recording/` needs UIKit, SwiftUI, AVFoundation, VideoToolbox and Photos, so it
must not enter the `HelmProtocol` target. That target already uses an explicit
`sources: ["HelmProtocol.swift", "RTSPCore"]` allowlist, so the new directory is not
compiled — but add it to `exclude:` next to `"RTSP"` so SwiftPM does not warn about
unhandled files:

```swift
            exclude: [
                "GarminDiscovery.swift",
                "HelmPairing.swift",
                "HelmSession.swift",
                "MirrorPlayerView.swift",
                "ContentView.swift",
                "HelmMirrorApp.swift",
                "Info.plist",
                "RTSP",                    // platform-only: Network / AVFoundation / UIKit
                "Recording"                // platform-only: AVFoundation / VideoToolbox / Photos
            ],
```

`Sources/RTSPCore/RecordingCore.swift` needs **no** manifest change: the `RTSPCore`
directory is already listed in `sources:` and picks up new files automatically.

---

## 10. Robustness matrix (requirement 6, exhaustively)

| Trigger | Who detects it | Stop reason | File outcome |
|---|---|---|---|
| User taps stop | `RecordingControlsBar` | `.user` | finalized, saved |
| Video reaches `.ended` / `.failed` | `MirrorScreen.onState` → `videoStopped()` | `.videoEnded` | finalized, saved |
| App backgrounds | `MirrorRecorder`'s own notification observer | `.backgrounded` | finalized under a `beginBackgroundTask`, saved |
| Back button | `MirrorScreen` | `.dismissed` | finalized, saved |
| View dismantled by SwiftUI | `MirrorVideoView.teardown()` | `.dismissed` | finalized, saved |
| Free space < 200 MiB | guard timer, 5 s granularity | `.lowStorage` | finalized, saved, error toast |
| 30 minutes elapsed | guard timer | `.reachedMaxDuration` | finalized, saved, toast |
| 2 GiB written | guard timer | `.reachedMaxSize` | finalized, saved, toast |
| SPS/PPS change | `noteParameterSets` → gate | `.formatChanged` | finalized, saved, toast. **No auto-restart.** |
| No keyframe within 300 units | gate | `.noKeyframe` | nothing written; no file left behind |
| `AVAssetWriter` fails | writer status | `.writerFailed(detail)` | **file deleted**, error toast |
| Writer backlog > 90 samples | pending counter | `.writerFailed("writer backlog")` | finalized if possible, else deleted |
| App killed mid-recording | nobody | — | `movieFragmentInterval = 5 s` leaves a playable prefix |
| `frames < 2` or 0 bytes on finalize | finalize check | `.writerFailed("empty file")` | **file deleted** |
| Photos access refused | `MediaLibrary` | — | file kept in Documents, share sheet offered |

Every row logs one `rec:` line. Nothing fails silently — that is the rule the whole
diagnostics system exists to enforce (`SPEC` §11), and it matters more here than anywhere
else in the app, because a recording that quietly did not happen is discovered at the dock,
hours later, when the fish is long gone.

---

## 11. Definition of done

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift run helmverify            # PASS, total strictly > 252

xcodegen generate
xcodebuild -project HelmMirror.xcodeproj -scheme HelmMirror \
  -destination 'generic/platform=iOS' -configuration Debug \
  -allowProvisioningUpdates build
```

On the boat, against the real plotter (device `AE53ACEB-A47C-583E-B64C-1CA0C37D269B`,
team `W93UVP5TF5`, `com.jimmy.helmmirror`):

1. Live mirror still works, with the same latency, before recording is ever touched.
2. Touches still drive the plotter everywhere except the documented corner.
3. Record → the file starts on a keyframe; AirDrop it to a Mac and confirm
   `ffprobe` reports `h264`, 1280x720, and that VLC plays it **from frame zero**.
4. Snapshot → the JPEG shows the frame that was on screen at the moment of the tap, not
   a frame from a second earlier and not a black rectangle.
5. Deny photo-library access → both files are still present in the Files app under
   HelmMirror, and the share sheet reaches Messages.
6. Background the app mid-recording, come back → the file is finalized and plays.
7. Record for 31 minutes → stops itself at 30:00 with a readable message.
8. The whole time, `MirrorDiagnostics` shows `rec:`/`snap:` lines and no per-frame spam.
