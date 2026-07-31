//
//  MediaLibrary.swift
//  HelmMirror
//
//  Saving a finished recording or a still into the user's photo library —
//  ADD-ONLY, always (SPEC-RECORDING §6).
//
//  Three rules shape everything below.
//
//    1. Add-only. `PHAccessLevel.addOnly` and `NSPhotoLibraryAddUsageDescription`
//       and nothing else. HelmMirror has no business reading the user's photos,
//       and asking for read access shows a materially scarier prompt for no
//       gain. There is no `PHPhotoLibraryChangeObserver`, no album creation and
//       no `PHAssetCollection` here: writing into the camera roll is the whole
//       feature.
//
//    2. The Documents copy is never deleted — not on success, not on failure.
//       Photos always gets a *copy* (`shouldMoveFile = false`; the video path's
//       `creationRequestForAssetFromVideo(atFileURL:)` copies by definition), so
//       the original stays in Documents where `UIFileSharingEnabled` makes it
//       reachable in the Files app. That is the fallback that has to survive a
//       refused permission.
//
//    3. A denial is a fact, not an error to retry. `.denied`/`.restricted` come
//       back as `.permissionDenied`; the caller keeps the file and offers the
//       share sheet (§7.3). iOS will not re-present the prompt, so re-requesting
//       only produces a silent no.
//
//  Callbacks. PhotoKit calls back on an arbitrary internal queue. Every
//  completion here is hopped to main, asynchronously and exactly once, so the
//  caller — `MirrorCaptureController`, which is `@MainActor` — never has to
//  think about it.
//
//  No diagnostics are logged from this file. The caller owns the `rec:`/`snap:`
//  vocabulary (§4.9, §7.3) and logging here as well would double every line in
//  a 40-line ring shared with the RTSP handshake.
//
//  UIKit is imported because §1.1 pins this file's framework set to
//  Foundation/Photos/UIKit. Nothing here presents UI: the share sheet itself is
//  `ShareSheet` in `Sources/Recording/RecordingControls.swift` (§7.2), and this
//  file's part in that fallback is to report `.permissionDenied` (or `.failed`)
//  clearly enough that the caller knows to offer it, while leaving the file on
//  disk for it to share.
//

import Foundation
import Photos
import UIKit

/// Add-only photo-library access: authorization plus two saves.
///
/// A namespace, not an object — there is no state worth owning. `PHPhotoLibrary`
/// is a process-wide singleton and both saves are one-shot transactions.
public enum MediaLibrary {

    /// The result of one save attempt.
    ///
    /// `.permissionDenied` is deliberately distinct from `.failed`: it is the
    /// only outcome that is expected, permanent, and answerable by the share
    /// sheet rather than by retrying.
    public enum SaveOutcome: Equatable, Sendable {
        case saved
        case permissionDenied
        /// Helm-readable detail, ≤ 80 characters so `rec: photos err <detail>`
        /// stays inside the 110-character diagnostics budget (SPEC §11).
        case failed(String)
    }

    // MARK: - Authorization

    /// The current add-only authorization status.
    public static var addOnlyStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// Request add-only authorization. `completion` is delivered on **main**.
    ///
    /// Callers must check `addOnlyStatus` first and not call this when it is
    /// `.denied` or `.restricted` — iOS will not re-present the prompt. This
    /// method enforces that contract rather than merely documenting it: anything
    /// other than `.notDetermined` short-circuits and reports the status it
    /// already has, which is exactly what PhotoKit would have returned anyway,
    /// minus the round trip.
    public static func requestAddOnlyAuthorization(_ completion: @escaping (PHAuthorizationStatus) -> Void) {
        let handoff = Handoff(completion)
        let status = addOnlyStatus
        guard status == .notDetermined else {
            handoff.deliver(status)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
            handoff.deliver(granted)
        }
    }

    // MARK: - Saving

    /// Save the MP4 at `url` into the camera roll. `completion` is on **main**.
    ///
    /// The file is copied, never moved: it stays in Documents for the Files app
    /// and for the share sheet.
    public static func saveVideo(at url: URL, completion: @escaping (SaveOutcome) -> Void) {
        save(url, as: .video, completion: completion)
    }

    /// Save the JPEG at `url` into the camera roll. `completion` is on **main**.
    ///
    /// Same copy-not-move rule as `saveVideo(at:completion:)`.
    public static func savePhoto(at url: URL, completion: @escaping (SaveOutcome) -> Void) {
        save(url, as: .photo, completion: completion)
    }

    // MARK: - Implementation

    private enum Asset: Sendable {
        case video
        case photo
    }

    private static func save(_ url: URL,
                             as asset: Asset,
                             completion: @escaping (SaveOutcome) -> Void) {
        let handoff = Handoff(completion)

        // Preflight 1 — the file. PhotoKit reports a missing file as a generic
        // transaction failure; naming the real problem is what makes the toast
        // and the diagnostic line worth reading.
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            handoff.deliver(.failed("The file is no longer on disk"))
            return
        }

        // Preflight 2 — authorization. Handing a refused library a transaction
        // just to be told no wastes a round trip and buries the reason in an
        // error code.
        switch addOnlyStatus {
        case .denied, .restricted:
            handoff.deliver(.permissionDenied)
            return
        default:
            break
        }

        // PhotoKit's change block returns `void`, so it cannot signal failure —
        // and `creationRequestForAssetFromVideo(atFileURL:)` returns nil for a
        // file the library will not accept, after which `performChanges`
        // reports *success* having saved nothing. This flag turns that silent
        // no-op into a reported failure. The block always runs to completion
        // before the completion handler, so the ordering is guaranteed; the
        // lock inside `AcceptanceFlag` is there because the two run on
        // different queues.
        let accepted = AcceptanceFlag()

        PHPhotoLibrary.shared().performChanges {
            switch asset {
            case .video:
                accepted.value = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) != nil
            case .photo:
                let options = PHAssetResourceCreationOptions()
                // Copy. The original is the user's fallback (rule 2 above).
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
                // `addResource` cannot fail synchronously — the request is
                // validated after the block, and any problem arrives as an
                // error in the completion handler.
                accepted.value = true
            }
        } completionHandler: { success, error in
            handoff.deliver(outcome(success: success, error: error, accepted: accepted.value))
        }
    }

    private static func outcome(success: Bool, error: Error?, accepted: Bool) -> SaveOutcome {
        if success && accepted { return .saved }

        if let error {
            // A library that was revoked between the preflight and the
            // transaction lands here rather than in the preflight, and it is
            // still a permission problem, not a failure to retry.
            if let photos = error as? PHPhotosError {
                switch photos.code {
                case .accessUserDenied, .accessRestricted:
                    return .permissionDenied
                case .notEnoughSpace:
                    return .failed("Not enough space in your photo library")
                default:
                    break
                }
            }
            return .failed(trimmed(error.localizedDescription))
        }

        if !accepted { return .failed("Photos would not accept the file") }
        return .failed("Photos did not save the file")
    }

    /// Matches `MirrorVideoView.trimmed(_:limit:)` so diagnostics read alike.
    private static func trimmed(_ s: String, limit: Int = 80) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    // MARK: - Cross-queue plumbing

    /// Carries a completion across PhotoKit's callback boundary and delivers it
    /// on main, asynchronously, exactly once.
    ///
    /// `@unchecked Sendable` is honest here: the stored closure is read only
    /// inside `fire(_:)`, which the main queue serializes, and nilling it there
    /// makes a second delivery impossible even if PhotoKit ever called back
    /// twice. Delivery is always asynchronous, including on the short-circuit
    /// paths, so the caller gets one predictable contract rather than a
    /// completion that sometimes reenters it before `save` has returned.
    private final class Handoff<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var body: ((Value) -> Void)?

        init(_ body: @escaping (Value) -> Void) {
            self.body = body
        }

        func deliver(_ value: Value) {
            // `self` crosses the queue boundary, not the closure: a non-Sendable
            // closure captured directly by `DispatchQueue.async` is an error
            // under Swift 6 strict concurrency.
            DispatchQueue.main.async { self.fire(value) }
        }

        private func fire(_ value: Value) {
            lock.lock()
            let body = self.body
            self.body = nil
            lock.unlock()
            body?(value)
        }
    }

    /// One bit written inside PhotoKit's change block and read in its completion
    /// handler, which run on different queues.
    private final class AcceptanceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return raised }
            set { lock.lock(); raised = newValue; lock.unlock() }
        }
    }
}
