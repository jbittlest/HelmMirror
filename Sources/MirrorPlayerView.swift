//
//  MirrorPlayerView.swift
//  HelmMirror
//
//  SwiftUI wrapper around a UIView that renders the plotter's live RTSP/H.264
//  stream and mirrors single/multi-finger touches back to the MFD.
//
//  Two jobs:
//    1. Video  — an `RTSPVideoSession` (native RTSP/RTP/H.264 over
//       Foundation + Network) feeding an `AVSampleBufferDisplayLayer` by way of
//       `H264VideoView`. MobileVLCKit is gone: its bundled live555 failed with
//       error -36 before a single RTSP byte was exchanged, on a stream that
//       ffplay plays without complaint (SPEC v2.0 §0).
//    2. Touch  — `touchesBegan/Moved/Ended/Cancelled` are converted to
//       normalized 0..1 coordinates against the displayed video content rect
//       (top-left origin) and handed to the injected `onTouch` closure. The
//       session layer turns those into 16.16 fixed-point TOUCH frames.
//
//  Depends only on the shared model types from HelmProtocol (`HelmTouchPoint`)
//  and on `Sources/RTSP/`, which compile into this same app module. No
//  session/pairing knowledge here.
//

import SwiftUI
import UIKit

/// `UIViewRepresentable` that plays `rtspURL` and reports normalized touches.
///
/// Present at the video's aspect ratio (default 16:9) so the content fills the
/// view and normalization is exact:
/// `MirrorPlayerView(rtspURL:onTouch:).aspectRatio(videoAspect, contentMode: .fit)`.
/// If the view is ever laid out at a different aspect, the backing view
/// letterboxes/pillarboxes internally and normalizes against the content rect.
/// A tiny in-app diagnostic log, shown on screen when playback fails.
///
/// Reading the device console requires the phone to be tethered and unlocked,
/// which is not workable on a boat. Putting the facts on screen means they can
/// simply be read off — including the literal RTSP request and response lines,
/// which is what makes a handshake failure diagnosable at the helm.
public final class MirrorDiagnostics: ObservableObject, @unchecked Sendable {
    public static let shared = MirrorDiagnostics()

    /// A full RTSP exchange is ~25 lines; anything smaller truncates away the
    /// part that explains the failure.
    private static let maxLines = 40
    /// RTSP lines arrive in bursts, so publishing every one of them straight to
    /// SwiftUI thrashes the main thread. Coalesce to 10 Hz.
    private static let publishInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private var lines: [String] = []
    private var publishScheduled = false
    @Published public private(set) var text: String = ""

    private init() {}

    public func log(_ message: String) {
        NSLog("[HelmMirror] %@", message)
        lock.lock()
        lines.append(message)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        lock.unlock()
        schedulePublish()
    }

    public func reset() {
        lock.lock(); lines.removeAll(); lock.unlock()
        DispatchQueue.main.async { self.text = "" }
    }

    /// Publish at most once per `publishInterval`, always with a snapshot taken
    /// at fire time so the last line of a burst is never lost.
    private func schedulePublish() {
        lock.lock()
        if publishScheduled { lock.unlock(); return }
        publishScheduled = true
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishInterval) { [self] in
            lock.lock()
            publishScheduled = false
            let snapshot = lines.joined(separator: "\n")
            lock.unlock()
            text = snapshot
        }
    }
}

/// What the player is doing, so the UI can say something instead of showing a
/// black rectangle. Without this a playback failure is completely invisible.
public enum MirrorPlaybackState: Equatable {
    case opening
    case buffering
    case playing
    case stalled
    case ended
    case failed

    public var isPlaying: Bool { self == .playing }

    public var message: String {
        switch self {
        case .opening:   return "Opening the video stream…"
        case .buffering: return "Buffering…"
        case .playing:   return "Playing"
        case .stalled:   return "Video stalled — waiting for the plotter"
        case .ended:     return "The plotter stopped sending video"
        case .failed:    return "Could not play the video stream"
        }
    }
}

/// One thing to try: a URL plus the transport to try it with.
///
/// The plotter offers several resolutions, and a transport can fail for reasons
/// that are invisible from the API. Rather than guess, walk a ladder of
/// combinations until one produces frames.
///
/// `useTCP` is now `preferTCP` (SPEC §5.4/§6.3): `false` means "UDP first, with
/// one automatic fallback to interleaved TCP inside the session", `true` means
/// "interleaved TCP only". In practice attempt 1 succeeds and the ladder is
/// never walked — it stays as the last safety net.
public struct MirrorAttempt: Equatable, Hashable {
    public let url: String
    public let useTCP: Bool

    public var label: String { "\(useTCP ? "TCP" : "UDP") \(url)" }

    /// Build the ladder: preferred URL then any alternate resolution, each over
    /// UDP first (what the protocol notes say the plotter wants) then TCP.
    public static func ladder(for url: String) -> [MirrorAttempt] {
        var urls = [url]
        // The plotter advertises the same stream at more than one size; if the
        // preferred one will not play, the other one is worth trying.
        for (a, b) in [("1280x720", "960x540"), ("960x540", "1280x720")] where url.contains(a) {
            let alt = url.replacingOccurrences(of: a, with: b)
            if !urls.contains(alt) { urls.append(alt) }
        }
        return urls.map { MirrorAttempt(url: $0, useTCP: false) }
             + urls.map { MirrorAttempt(url: $0, useTCP: true) }
    }
}

public struct MirrorPlayerView: UIViewRepresentable {
    public let rtspURL: String
    public let useTCP: Bool
    public let videoAspect: CGFloat
    /// Optional recording/snapshot tee (SPEC-RECORDING §9.1). Nil — the default —
    /// means the player behaves exactly as it did before recording existed.
    public let capture: MirrorCaptureController?
    public let onTouch: ([HelmTouchPoint]) -> Void
    public let onState: (MirrorPlaybackState) -> Void

    /// `capture:` is placed before `onTouch:` and defaulted, so every existing
    /// labelled call site stays source-compatible and unchanged in behaviour.
    public init(rtspURL: String,
                useTCP: Bool = false,
                videoAspect: CGFloat = 1280.0 / 720.0,
                capture: MirrorCaptureController? = nil,
                onTouch: @escaping ([HelmTouchPoint]) -> Void,
                onState: @escaping (MirrorPlaybackState) -> Void = { _ in }) {
        self.rtspURL = rtspURL
        self.useTCP = useTCP
        self.videoAspect = videoAspect
        self.capture = capture
        self.onTouch = onTouch
        self.onState = onState
    }

    public func makeUIView(context: Context) -> UIView {
        let view = MirrorVideoView()
        view.videoAspect = videoAspect
        view.onTouch = onTouch
        view.onState = onState
        view.capture = capture
        view.play(urlString: rtspURL, useTCP: useTCP)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? MirrorVideoView else { return }
        // Refresh the live values SwiftUI may have rebuilt this render.
        view.videoAspect = videoAspect
        view.onTouch = onTouch
        view.onState = onState
        view.capture = capture
        // `play` is a no-op unless the URL or transport actually changed.
        view.play(urlString: rtspURL, useTCP: useTCP)
    }

    public static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? MirrorVideoView)?.teardown()
    }
}

// MARK: - Backing view

/// The concrete `UIView` the decoded stream is displayed in and that captures
/// touches. `H264VideoView` owns the `AVSampleBufferDisplayLayer` and the
/// `CMVideoFormatDescription`; this subclass owns the session and the touches.
final class MirrorVideoView: H264VideoView {

    /// The live RTSP/RTP/H.264 session driving the layer above. Nil when idle.
    private var session: RTSPVideoSession?

    /// Reports playback state upward. Without this a failure is silent and the
    /// user just sees black, which is exactly what happened on first use.
    var onState: ((MirrorPlaybackState) -> Void)?
    private var lastReported: MirrorPlaybackState?

    /// The URL currently loaded into the player; guards redundant restarts.
    private var currentURLString: String?

    /// Aspect ratio of the source video (width / height). Used only when the
    /// view is not laid out at this exact ratio, to find the content rect.
    var videoAspect: CGFloat = 1280.0 / 720.0

    /// Sink for normalized touch batches. Set by the representable each update.
    var onTouch: (([HelmTouchPoint]) -> Void)?

    /// The recording/snapshot tee (SPEC-RECORDING §9.1).
    ///
    /// Lock-guarded because SwiftUI writes it on main while the video queue
    /// reads it on every access unit. An uncontended `NSLock` is ~20 ns, i.e.
    /// ~1.8 µs per second at 30 fps — nothing next to a frame's decode.
    private let captureLock = NSLock()
    private var _capture: MirrorCaptureController?
    var capture: MirrorCaptureController? {
        get {
            captureLock.lock()
            defer { captureLock.unlock() }
            return _capture
        }
        set {
            captureLock.lock()
            _capture = newValue
            captureLock.unlock()
            // The snapshot path wants the renderer's layer for its iOS 17.4+
            // fast path. `attach` is nonisolated and hops to main itself.
            newValue?.attach(displayLayer: displayLayer)
        }
    }

    // Stable per-finger `track_id`s. A `UITouch` instance is reused by UIKit
    // across a finger's lifetime, so its `ObjectIdentifier` is a stable key.
    // We assign the smallest free id on first sight and release it on end/cancel.
    private var trackIds: [ObjectIdentifier: UInt8] = [:]
    private var usedIds: Set<UInt8> = []

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureMirrorView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMirrorView()
    }

    /// The mirror-specific half of `commonInit` (the layer half lives in
    /// `H264VideoView`): black backing, and multi-touch actually enabled —
    /// without `isMultipleTouchEnabled` UIKit delivers only one finger.
    private func configureMirrorView() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        // The video pipeline reports these three on main; they are the only
        // player-side facts the on-screen log cannot get from the RTSP layer.
        onVideoSizeChanged = { size in
            MirrorDiagnostics.shared.log("fmt: \(Int(size.width))x\(Int(size.height))")
        }
        onFirstFrame = {
            MirrorDiagnostics.shared.log("video: first frame")
        }
        onDecodeFailure = { reason in
            MirrorDiagnostics.shared.log("video: decode failed — \(Self.trimmed(reason))")
        }
    }

    // MARK: Playback

    /// Load `urlString` and start playback. Idempotent for an unchanged attempt.
    func play(urlString: String, useTCP: Bool = false) {
        let key = "\(useTCP ? "tcp" : "udp")|\(urlString)"
        guard key != currentURLString else { return }
        currentURLString = key

        MirrorDiagnostics.shared.log("try \(useTCP ? "TCP" : "UDP") \(urlString)")

        // SwiftUI reuses this view when only the attempt changes, so a previous
        // session may still be running. Drop it, and the stale format
        // description with it, before starting the next one.
        session?.stop()
        session = nil
        reset()
        lastReported = nil

        guard URL(string: urlString) != nil else {
            MirrorDiagnostics.shared.log("err: badURL(\(urlString))")
            emit(.failed)
            return
        }

        let session = RTSPVideoSession(url: urlString, preferTCP: useTCP)
        // Parameter sets and access units arrive on the session's video queue;
        // both of these are documented safe to call from it.
        // The tee runs AFTER the display call, always. The mirror's latency is
        // the product; nothing may be inserted ahead of `enqueue`.
        session.onParameterSets = { [weak self] ps in
            guard let self else { return }
            self.setParameterSets(sps: ps.sps, pps: ps.pps)
            self.capture?.noteParameterSets(ps)
        }
        session.onAccessUnit = { [weak self] au in
            guard let self else { return }
            self.enqueue(accessUnit: au.avcc,
                         isKeyframe: au.isKeyframe,
                         rtpTimestamp: au.rtpTimestamp)
            self.capture?.append(au)
        }
        session.onState = { [weak self] state in
            self?.emit(state)
        }
        self.session = session
        session.start()
    }

    /// Stop playback and release resources. Called from `dismantleUIView`.
    func teardown() {
        // Detach the tee first, so nothing can be appended to a recording that
        // is already closing. `dismantleUIView` runs on main; the hop is there
        // because `stopEverything` is `@MainActor` and `teardown` is not.
        let c = capture
        capture = nil
        Task { @MainActor in c?.stopEverything(reason: .dismissed) }

        session?.stop()
        session = nil
        reset()
        currentURLString = nil
        lastReported = nil
    }

    /// Report a state change upward, once per distinct state.
    private func emit(_ mapped: MirrorPlaybackState) {
        guard mapped != lastReported else { return }
        lastReported = mapped
        let sink = onState
        DispatchQueue.main.async { sink?(mapped) }
    }

    /// SPEC §11: no diagnostic line may run past ~110 characters.
    private static func trimmed(_ s: String, limit: Int = 80) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    // MARK: Touch capture

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, event: event, down: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, event: event, down: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, event: event, down: false)
        releaseIds(for: touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        emit(touches, event: event, down: false)
        releaseIds(for: touches)
    }

    /// Convert a set of `UITouch`es to normalized `HelmTouchPoint`s and deliver
    /// them in one `onTouch` call. During presses/moves we expand
    /// `coalescedTouches` into multiple points for smoother, higher-rate drags.
    private func emit(_ touches: Set<UITouch>, event: UIEvent?, down: Bool) {
        guard let onTouch else { return }
        let rect = contentRect()
        guard rect.width > 0, rect.height > 0 else { return }

        var points: [HelmTouchPoint] = []
        for touch in touches {
            let id = trackId(for: touch)
            // Coalesced samples exist only for began/moved; use them to capture
            // the intermediate positions UIKit dropped between screen refreshes.
            let samples: [UITouch] = down ? (event?.coalescedTouches(for: touch) ?? [touch])
                                          : [touch]
            for sample in samples {
                let p = sample.location(in: self)
                let nx = clamp01(Double((p.x - rect.minX) / rect.width))
                let ny = clamp01(Double((p.y - rect.minY) / rect.height))
                points.append(HelmTouchPoint(trackId: id, nx: nx, ny: ny, down: down))
            }
        }
        if !points.isEmpty { onTouch(points) }
    }

    // MARK: Track-id bookkeeping

    private func trackId(for touch: UITouch) -> UInt8 {
        let key = ObjectIdentifier(touch)
        if let existing = trackIds[key] { return existing }
        let id = nextFreeId()
        trackIds[key] = id
        usedIds.insert(id)
        return id
    }

    private func nextFreeId() -> UInt8 {
        var id: UInt8 = 0
        while usedIds.contains(id) { id &+= 1 }
        return id
    }

    private func releaseIds(for touches: Set<UITouch>) {
        for touch in touches {
            if let id = trackIds.removeValue(forKey: ObjectIdentifier(touch)) {
                usedIds.remove(id)
            }
        }
    }

    // MARK: Geometry

    /// The rectangle the video actually occupies inside `bounds`. When the view
    /// is already at `videoAspect` this is `bounds`; otherwise it is the
    /// letterboxed/pillarboxed content rect (SPEC §7.4 aspect rule).
    ///
    /// `videoAspect` comes from the representable and is deliberately NOT
    /// overwritten by the SPS-derived `videoSize`: the SwiftUI
    /// `.aspectRatio(...)` modifier defines the layout, so overriding it here
    /// would silently break the touch mapping. The SPS size is logged instead.
    private func contentRect() -> CGRect {
        let W = bounds.width
        let H = bounds.height
        guard W > 0, H > 0 else { return bounds }

        let viewAspect = W / H
        if abs(viewAspect - videoAspect) < 0.001 {
            return bounds
        }
        if viewAspect > videoAspect {
            // View is wider than the video: pillarbox (full height, centered).
            let w = H * videoAspect
            return CGRect(x: (W - w) / 2, y: 0, width: w, height: H)
        } else {
            // View is taller than the video: letterbox (full width, centered).
            let h = W / videoAspect
            return CGRect(x: 0, y: (H - h) / 2, width: W, height: h)
        }
    }

    private func clamp01(_ v: Double) -> Double {
        min(max(v, 0), 1)
    }
}
