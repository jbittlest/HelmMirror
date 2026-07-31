//
//  MirrorCaptureController.swift
//  HelmMirror
//
//  The single object SwiftUI binds to and the mirror UIView tees into
//  (SPEC-RECORDING §7.1). It owns the passthrough recorder and the snapshot
//  ring, and it is the only place those two features know about each other.
//
//  Isolation, which is the whole design:
//
//    · The class is `@MainActor`. Every published property, every user action
//      and every lifecycle hook runs on main, so SwiftUI never observes a
//      half-updated bar.
//    · The three tee entry points — `attach`, `noteParameterSets`, `append` —
//      are `nonisolated` and are called from the RTSP session's serial video
//      queue, 30 times a second, AFTER the display path. They must never block
//      it and they must never hop to main. They therefore touch nothing that
//      main owns: only `TeeState`, an `NSLock`-guarded box, and the two media
//      objects, both of which are internally thread-safe by construction.
//
//  Requirement 7 taken literally: `MirrorRecorder` is created lazily, on the
//  first `toggleRecording()`. Until then `append` forwards to the snapshot ring
//  alone and the recorder does not exist — recording is off by default and
//  costs nothing.
//
//  A recorder created mid-stream would otherwise never learn the format:
//  parameter sets are only re-emitted when they CHANGE, so a recorder armed
//  between two changes would skip every unit with `no format`. `TeeState`
//  latches the last sets seen and hands them to the recorder at the instant it
//  is installed, under the same lock, so there is no window.
//

import SwiftUI
import AVFoundation

// MARK: - Toast

/// One line of "where the file went", shown over the bar for a few seconds.
///
/// A non-nil `shareURL` makes the toast tappable and is what §7.3's Files
/// fallback is offered through. Nothing is ever auto-presented.
public struct CaptureToast: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// ≤ 60 characters — it sits in a capsule over live video.
    public let text: String
    /// SF Symbol name.
    public let symbol: String
    public let isError: Bool
    /// Non-nil ⇒ the toast is tappable and presents a share sheet for this file.
    public let shareURL: URL?

    public init(id: UUID = UUID(),
                text: String,
                symbol: String,
                isError: Bool,
                shareURL: URL? = nil) {
        self.id = id
        self.text = text
        self.symbol = symbol
        self.isError = isError
        self.shareURL = shareURL
    }
}

// MARK: - Controller

@MainActor
public final class MirrorCaptureController: ObservableObject {

    // MARK: Published state (main)

    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var recordedBytes: Int64 = 0
    @Published public private(set) var freeBytes: Int64 = 0
    @Published public private(set) var controlsVisible: Bool = true
    /// Drives the 150 ms white shutter flash. Always `allowsHitTesting(false)`.
    @Published public private(set) var flash: Bool = false
    @Published public private(set) var toast: CaptureToast?

    // MARK: Media (reachable from the video queue)

    /// Armed and disarmed from main; its own lock guards the ring, so the tee
    /// reaches it directly. `nonisolated` because `append` does.
    private nonisolated let snapshots = SnapshotCapture()

    /// The lock-guarded box the tee reads. Main writes it exactly twice per
    /// recorder: on creation and never again (the recorder itself is reusable).
    private nonisolated let tee = TeeState()

    /// Main's own reference to the same recorder, so the actions below do not
    /// have to take the tee's lock on every tap.
    private var recorder: MirrorRecorder?

    // MARK: Timers (main)

    private var autoHideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    private static let flashDuration: TimeInterval = 0.15
    /// A toast that can be tapped has to survive long enough to be tapped.
    private static let toastDurationWithShare: TimeInterval = 4
    private static let toastDuration: TimeInterval = 2

    public init() {}

    deinit {
        autoHideTask?.cancel()
        toastTask?.cancel()
        flashTask?.cancel()
    }

    // MARK: - User actions

    /// The red button.
    public func toggleRecording() {
        if isRecording {
            recorder?.stop(reason: .user)
            return
        }

        refreshFreeBytes()

        let recorder = ensureRecorder()
        // `start()` re-reads free space itself and logs its own `rec: err …`,
        // so the refusal only has to be shown, not narrated twice.
        if let refusal = recorder.start() {
            showToast(text: refusal.message,
                      symbol: "exclamationmark.triangle.fill",
                      isError: true)
            return
        }

        elapsed = 0
        recordedBytes = 0
        setRecording(true)
        // Pin the bar: while recording it does not auto-hide (§7.1), so the
        // elapsed time and the stop button stay reachable.
        controlsVisible = true
    }

    /// The camera button.
    public func takeSnapshot() {
        // The shutter fires before the JPEG exists. A camera that feels
        // delayed feels broken, and the encode is not instant.
        triggerFlash()

        snapshots.capture { [weak self] result in
            // `SnapshotCapture` guarantees main delivery; this closure is not
            // `@Sendable`, so it inherits this method's main-actor isolation.
            guard let self else { return }
            switch result {
            case .success(let still):
                self.save(still.url, kind: .photo)
            case .failure(let failure):
                self.showToast(text: failure.message,
                               symbol: "exclamationmark.triangle.fill",
                               isError: true)
            }
        }
    }

    /// Show the bar and restart the auto-hide timer. Called by every control.
    public func revealControls() {
        let wasHidden = !controlsVisible
        controlsVisible = true
        if wasHidden { refreshFreeBytes() }
        scheduleAutoHide()
    }

    // MARK: - Lifecycle

    /// The mirror screen appeared: arm the snapshot ring, refresh free space.
    public func viewAppeared() {
        snapshots.isArmed = true
        refreshFreeBytes()
        controlsVisible = true
        scheduleAutoHide()
    }

    /// Back, `onDisappear`, or `dismantleUIView`. Stops recording and disarms
    /// the ring, so an off-screen mirror retains nothing. Idempotent:
    /// `MirrorRecorder.stop` ignores a recorder that is not active, and
    /// disarming an already-disarmed ring is a lock and a `Bool`.
    public func stopEverything(reason: RecordingStopReason) {
        autoHideTask?.cancel()
        autoHideTask = nil
        flashTask?.cancel()
        flashTask = nil
        flash = false
        snapshots.isArmed = false
        recorder?.stop(reason: reason)
    }

    /// Playback reached `.playing`. Re-arms the snapshot ring.
    ///
    /// This exists because `MirrorScreen` attaches `.id(attempt)` to the player,
    /// so every step of the URL/transport ladder dismantles the UIView — which
    /// runs `teardown()`, which calls `stopEverything(.dismissed)`, which
    /// disarms the ring. `viewAppeared()` fires once, on the screen's
    /// `onAppear`, and never again, so without this the snapshot button would be
    /// dead for the rest of the session on any boat where attempt 1 does not
    /// produce video inside the 8-second timeout.
    ///
    /// Keyed off `.isPlaying` rather than off `attach(displayLayer:)` because
    /// frames arriving is the one signal that is strictly ORDERED after both the
    /// old view's dismantle and the new view's creation; two `@MainActor` hops
    /// racing each other are not.
    public func videoStarted() {
        snapshots.isArmed = true
        refreshFreeBytes()
    }

    /// Playback reached `.ended` or `.failed`. Deliberately NOT called for
    /// `.stalled`: the session gives a stall 10 s to recover and MP4 expresses
    /// the gap as a longer sample duration, so losing a file to a five-second
    /// Wi-Fi hiccup at the helm would be the worse outcome.
    public func videoStopped() {
        guard isRecording else { return }
        recorder?.stop(reason: .videoEnded)
    }

    // MARK: - The tee (video queue)

    /// Hand the snapshot path the renderer's layer, for its iOS 17.4+ fast path.
    ///
    /// Called from `MirrorVideoView`'s `capture` setter, which SwiftUI drives on
    /// main — but the setter is reachable from the video queue in principle, and
    /// `SnapshotCapture.displayLayer` is documented main-only, so this always
    /// hops rather than assuming.
    public nonisolated func attach(displayLayer: AVSampleBufferDisplayLayer) {
        let box = LayerBox(layer: displayLayer)
        Task { @MainActor [weak self] in
            self?.snapshots.displayLayer = box.layer
        }
    }

    /// On the RTSP session's video queue, after the display path.
    public nonisolated func noteParameterSets(_ sets: H264ParameterSets) {
        tee.latch(sets)
        tee.recorder?.noteParameterSets(sets)
        snapshots.noteParameterSets(sets)
    }

    /// On the RTSP session's video queue, after the display path. While
    /// recording is off this is one uncontended lock plus one array append.
    public nonisolated func append(_ unit: H264AccessUnit) {
        tee.recorder?.append(unit)
        snapshots.append(unit)
    }

    // MARK: - Recorder wiring

    private func ensureRecorder() -> MirrorRecorder {
        if let recorder { return recorder }

        let created = MirrorRecorder()
        // These three are plain (non-`@Sendable`) closure properties, so each
        // literal inherits this method's main-actor isolation — which is where
        // `MirrorRecorder` documents that it delivers them.
        created.onProgress = { [weak self] elapsed, bytes in
            guard let self else { return }
            self.elapsed = elapsed
            self.recordedBytes = bytes
        }
        created.onFinished = { [weak self] result, reason in
            guard let self else { return }
            self.recordingFinished(result, reason)
        }

        recorder = created
        // Installing and reading the latched sets under one lock is what closes
        // the window where a recorder armed between two parameter-set changes
        // would never learn the format.
        if let latched = tee.install(created) {
            created.noteParameterSets(latched)
        }
        return created
    }

    private func recordingFinished(_ result: MirrorRecorder.Result?,
                                   _ reason: RecordingStopReason) {
        setRecording(false)
        elapsed = 0
        recordedBytes = 0
        refreshFreeBytes()

        if reason.isFailure {
            showToast(text: reason.message,
                      symbol: "exclamationmark.triangle.fill",
                      isError: true)
        } else if result == nil {
            showToast(text: reason.message, symbol: "stop.circle.fill", isError: false)
        }

        // A file that exists is saved even when the stop was a failure — a
        // 30-minute limit or a low-storage stop still leaves usable footage —
        // and the save's own toast then replaces the reason above.
        if let result {
            save(result.url, kind: .video)
        }
    }

    private func setRecording(_ recording: Bool) {
        guard isRecording != recording else { return }
        isRecording = recording
        // The bar is pinned while recording, so the auto-hide timer has to be
        // re-armed on the way out or it stays on screen forever.
        scheduleAutoHide()
    }

    // MARK: - The save flow (§7.3)

    private enum SavedKind {
        case video
        case photo

        /// The diagnostics prefix, so `rec:` and `snap:` lines stay distinct.
        var tag: String { self == .video ? "rec" : "snap" }
    }

    private func save(_ url: URL, kind: SavedKind) {
        switch MediaLibrary.addOnlyStatus {

        case .authorized, .limited:
            performSave(url, kind: kind)

        case .notDetermined:
            MediaLibrary.requestAddOnlyAuthorization { [weak self] status in
                guard let self else { return }
                switch status {
                case .authorized, .limited:
                    self.performSave(url, kind: kind)
                default:
                    self.keptInFiles(url, kind: kind, text: "Saved to Files")
                }
            }

        case .denied, .restricted:
            // iOS will not re-present the prompt, so re-requesting only produces
            // a silent no. Say where the file is instead.
            keptInFiles(url, kind: kind, text: "Saved to Files — Photos access is off")

        @unknown default:
            keptInFiles(url, kind: kind, text: "Saved to Files")
        }
    }

    private func performSave(_ url: URL, kind: SavedKind) {
        let completion: (MediaLibrary.SaveOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .saved:
                MirrorDiagnostics.shared.log("\(kind.tag): photos saved")
                self.showToast(text: "Saved to Photos",
                               symbol: "checkmark.circle.fill",
                               isError: false)
            case .permissionDenied:
                self.keptInFiles(url, kind: kind, text: "Saved to Files")
            case .failed(let detail):
                MirrorDiagnostics.shared.log("\(kind.tag): photos err \(detail)")
                self.showToast(text: "Saved to Files",
                               symbol: "folder.fill",
                               isError: false,
                               shareURL: url)
            }
        }

        switch kind {
        case .video: MediaLibrary.saveVideo(at: url, completion: completion)
        case .photo: MediaLibrary.savePhoto(at: url, completion: completion)
        }
    }

    /// The file stayed in Documents, which is the whole point of
    /// `UIFileSharingEnabled`. The toast carries the URL so it can be shared.
    private func keptInFiles(_ url: URL, kind: SavedKind, text: String) {
        MirrorDiagnostics.shared.log("\(kind.tag): photos denied — kept in Files")
        showToast(text: text, symbol: "folder.fill", isError: false, shareURL: url)
    }

    // MARK: - Bar plumbing

    private func showToast(text: String,
                           symbol: String,
                           isError: Bool,
                           shareURL: URL? = nil) {
        toastTask?.cancel()
        let next = CaptureToast(text: text, symbol: symbol, isError: isError, shareURL: shareURL)
        toast = next
        // A toast is information, not a control: it must never be the reason
        // the bar is on screen, so it does not touch the auto-hide timer.
        let lifetime = shareURL == nil ? Self.toastDuration : Self.toastDurationWithShare
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.toast?.id == next.id { self.toast = nil }
        }
    }

    private func triggerFlash() {
        flashTask?.cancel()
        flash = true
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flashDuration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.flash = false
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        // §7.1: while recording the bar does not auto-hide. The elapsed time and
        // the stop button have to stay where a hand can find them on a moving boat.
        guard !isRecording else { return }

        autoHideTask = Task { @MainActor [weak self] in
            let delay = RecordingControlsPlacement.autoHideDelay
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isRecording else { return }
            self.controlsVisible = false
        }
    }

    /// One `URLResourceValues` read. Cheap, and only on the paths that show it.
    private func refreshFreeBytes() {
        freeBytes = MirrorRecorder.availableBytes(at: MirrorRecorder.defaultDirectory)
    }

    // MARK: - Cross-queue plumbing

    /// The recorder reference and the latched parameter sets, shared between
    /// main (which installs) and the video queue (which reads every frame).
    ///
    /// `@unchecked Sendable` is honest: both fields are only ever read or
    /// written under `lock`, and neither the lock nor a CoreMedia call is ever
    /// held across the other.
    private final class TeeState: @unchecked Sendable {
        private let lock = NSLock()
        private var _recorder: MirrorRecorder?
        private var _sets: H264ParameterSets?

        /// Read on the video queue, once per frame. An uncontended `NSLock` is
        /// ~20 ns; at 30 fps that is under two microseconds a second.
        var recorder: MirrorRecorder? {
            lock.lock()
            defer { lock.unlock() }
            return _recorder
        }

        func latch(_ sets: H264ParameterSets) {
            lock.lock()
            _sets = sets
            lock.unlock()
        }

        /// Install `recorder` and return the sets it has to be told about, in
        /// one critical section — so a parameter-set change cannot slip between
        /// the install and the catch-up and be lost by both.
        func install(_ recorder: MirrorRecorder) -> H264ParameterSets? {
            lock.lock()
            defer { lock.unlock() }
            _recorder = recorder
            return _sets
        }
    }

    /// `AVSampleBufferDisplayLayer` is not `Sendable`. Ownership moves with the
    /// box to main, which is the only place it is ever stored or read.
    private struct LayerBox: @unchecked Sendable {
        let layer: AVSampleBufferDisplayLayer
    }
}
