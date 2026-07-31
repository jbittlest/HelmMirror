//
//  MirrorPlayerView.swift
//  HelmMirror
//
//  SwiftUI wrapper around a VLC-backed UIView that renders the plotter's live
//  RTSP/H.264 stream and mirrors single/multi-finger touches back to the MFD.
//
//  Two jobs:
//    1. Video  — a `VLCMediaPlayer` drawing into the backing view, tuned for
//       low latency. Transport is left at MobileVLCKit's default (RTP/AVP/UDP);
//       we NEVER set `:rtsp-tcp` because the plotter rejects TCP-interleaved
//       transport with "461 Unsupported transport" (SPEC §4.11).
//    2. Touch  — `touchesBegan/Moved/Ended/Cancelled` are converted to
//       normalized 0..1 coordinates against the displayed video content rect
//       (top-left origin) and handed to the injected `onTouch` closure. The
//       session layer turns those into 16.16 fixed-point TOUCH frames.
//
//  Depends only on the shared model types from HelmProtocol (`HelmTouchPoint`),
//  which compile into this same app module. No session/pairing knowledge here.
//

import SwiftUI
import UIKit
import MobileVLCKit

/// `UIViewRepresentable` that plays `rtspURL` and reports normalized touches.
///
/// Present at the video's aspect ratio (default 16:9) so the content fills the
/// view and normalization is exact:
/// `MirrorPlayerView(rtspURL:onTouch:).aspectRatio(videoAspect, contentMode: .fit)`.
/// If the view is ever laid out at a different aspect, the backing view
/// letterboxes/pillarboxes internally and normalizes against the content rect.
/// What the player is doing, so the UI can say something instead of showing a
/// black rectangle. Without this a VLC failure is completely invisible.
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

public struct MirrorPlayerView: UIViewRepresentable {
    public let rtspURL: String
    public let videoAspect: CGFloat
    public let onTouch: ([HelmTouchPoint]) -> Void
    public let onState: (MirrorPlaybackState) -> Void

    public init(rtspURL: String,
                videoAspect: CGFloat = 1280.0 / 720.0,
                onTouch: @escaping ([HelmTouchPoint]) -> Void,
                onState: @escaping (MirrorPlaybackState) -> Void = { _ in }) {
        self.rtspURL = rtspURL
        self.videoAspect = videoAspect
        self.onTouch = onTouch
        self.onState = onState
    }

    public func makeUIView(context: Context) -> UIView {
        let view = MirrorVideoView()
        view.videoAspect = videoAspect
        view.onTouch = onTouch
        view.onState = onState
        view.play(urlString: rtspURL)
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? MirrorVideoView else { return }
        // Refresh the live values SwiftUI may have rebuilt this render.
        view.videoAspect = videoAspect
        view.onTouch = onTouch
        view.onState = onState
        // `play` is a no-op unless the URL actually changed, so this is cheap
        // even though SwiftUI calls updateUIView frequently.
        view.play(urlString: rtspURL)
    }

    public static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? MirrorVideoView)?.teardown()
    }
}

// MARK: - Backing view

/// The concrete `UIView` VLC draws into and that captures touches.
final class MirrorVideoView: UIView, VLCMediaPlayerDelegate {

    private let player = VLCMediaPlayer()

    /// Reports playback state upward. Without a delegate a VLC failure is silent
    /// and the user just sees black, which is exactly what happened on first use.
    var onState: ((MirrorPlaybackState) -> Void)?
    private var lastReported: MirrorPlaybackState?

    /// VLC reports `.playing` as soon as it has opened the stream, even when no
    /// picture is being produced — which looked like a hang behind a black view.
    /// `hasVideoOut` is the honest signal, so poll it and only claim `.playing`
    /// once frames really exist.
    private var videoWatch: Timer?

    /// Set once we have seen real video output; used to tell "never started" from
    /// "started then stopped".
    private var sawVideoOut = false

    /// The URL currently loaded into the player; guards redundant restarts.
    private var currentURLString: String?

    /// Aspect ratio of the source video (width / height). Used only when the
    /// view is not laid out at this exact ratio, to find the content rect.
    var videoAspect: CGFloat = 1280.0 / 720.0

    /// Sink for normalized touch batches. Set by the representable each update.
    var onTouch: (([HelmTouchPoint]) -> Void)?

    // Stable per-finger `track_id`s. A `UITouch` instance is reused by UIKit
    // across a finger's lifetime, so its `ObjectIdentifier` is a stable key.
    // We assign the smallest free id on first sight and release it on end/cancel.
    private var trackIds: [ObjectIdentifier: UInt8] = [:]
    private var usedIds: Set<UInt8> = []

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        player.drawable = self
        player.delegate = self
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        report(for: player.state)
    }

    private func report(for state: VLCMediaPlayerState) {
        let mapped: MirrorPlaybackState
        switch state {
        case .opening:   mapped = .opening
        // Never claim .playing on VLC's word alone — require real video output,
        // otherwise the UI hides its overlay and leaves a bare black screen.
        case .buffering: mapped = hasRealVideo ? .playing : .buffering
        case .playing:   mapped = hasRealVideo ? .playing : .buffering
        case .error:     mapped = .failed
        case .ended:     mapped = .ended
        case .stopped:   mapped = sawVideoOut ? .ended : .failed
        case .paused:    mapped = .stalled
        default:         return          // .esAdded and friends: not interesting
        }
        emit(mapped)
    }

    /// True only when VLC has an active video output producing a sized picture.
    private var hasRealVideo: Bool {
        guard player.hasVideoOut else { return false }
        let size = player.videoSize
        return size.width > 0 && size.height > 0
    }

    private func emit(_ mapped: MirrorPlaybackState) {
        if mapped == .playing { sawVideoOut = true }
        guard mapped != lastReported else { return }
        lastReported = mapped
        let sink = onState
        DispatchQueue.main.async { sink?(mapped) }
    }

    /// Poll for video output. State-change notifications alone are not enough:
    /// VLC can sit in `.playing` and only later start (or never start) producing
    /// frames, and it does not fire a state change when that happens.
    private func startVideoWatch() {
        videoWatch?.invalidate()
        videoWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.hasRealVideo {
                self.emit(.playing)
            } else if self.lastReported == .playing {
                // We had a picture and lost it.
                self.emit(.stalled)
            }
        }
    }

    // MARK: Playback

    /// Load `urlString` and start playback. Idempotent for an unchanged URL.
    func play(urlString: String) {
        guard urlString != currentURLString else { return }
        currentURLString = urlString
        guard let url = URL(string: urlString) else { return }

        let media = VLCMedia(url: url)
        // Low-latency live tuning. Do NOT add ":rtsp-tcp" — UDP transport only.
        // `network-caching` (ms) is the primary latency knob (100–200 ms).
        media.addOptions([
            "network-caching": 150,
            "live-caching": 150,
            "clock-jitter": 0,
            "clock-synchro": 0,
            "rtsp-frame-buffer-size": 500000
        ])
        player.media = media
        // Re-assert the drawable here as well as in init: at init time this view
        // has a zero frame, and VLC can fail to bring up a video output when the
        // drawable has no size yet — which renders as a permanent black screen.
        player.drawable = self
        sawVideoOut = false
        lastReported = nil
        player.play()
        startVideoWatch()
    }

    /// Stop playback and release the drawable. Called from `dismantleUIView`.
    func teardown() {
        videoWatch?.invalidate()
        videoWatch = nil
        if player.isPlaying { player.stop() }
        player.drawable = nil
        player.media = nil
        currentURLString = nil
        sawVideoOut = false
        lastReported = nil
    }

    // MARK: Touch capture

    /// VLC needs a drawable with a real size to create its video output. This view
    /// is constructed at zero size, so re-attach the first time we get real bounds
    /// and nudge playback if nothing is coming out yet. Without this the player can
    /// sit in `.playing` forever with a blank picture.
    private var attachedWithRealSize = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !attachedWithRealSize, bounds.width > 1, bounds.height > 1 else { return }
        attachedWithRealSize = true
        guard player.media != nil, !hasRealVideo else { return }
        player.drawable = self
        if !player.isPlaying { player.play() }
    }

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
