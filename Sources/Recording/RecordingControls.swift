//
//  RecordingControls.swift
//  HelmMirror
//
//  The recording/snapshot overlay bar (SPEC-RECORDING §7.2), plus the share
//  sheet that is offered whenever a file could not go to Photos (§7.3).
//
//  THE TOUCH CONTRACT — read this before changing a single modifier.
//
//  `MirrorVideoView` receives a touch only where SwiftUI does not hit-test
//  something above it, and those touches are the product: they drive the
//  plotter. This bar is therefore sized to its content and nothing else:
//
//    * the root has `.fixedSize()` and contains no `Spacer()`, no
//      `.frame(maxWidth: .infinity)` and no `.frame(maxHeight: .infinity)`;
//    * it is attached with `.overlay(alignment:)`, which never expands it;
//    * the shutter flash is drawn with a deliberately oversized fixed frame
//      inside a `.background` (a layer that cannot feed size back into the
//      parent) and is `.allowsHitTesting(false)`, so covering the screen
//      costs zero touch area;
//    * a toast that carries no share URL is `.allowsHitTesting(false)` too;
//      one that does carry a share URL is a Button, because §7.3 makes it
//      tappable, and it is only on screen for four seconds;
//    * no gesture modifier and no `.contentShape` is attached to anything
//      that covers the video — only to the buttons themselves.
//
//  The resulting dead zone is the documented one: 88 x 56 pt plus a 12 pt
//  inset in the bottom-leading corner while hidden, and roughly 230 x 60 pt
//  while expanded. Everything else on the surface stays a plotter target.
//  Do not "fix" this later by widening the overlay.
//
//  This file owns no media plumbing. It reads `MirrorCaptureController`
//  (§7.1) and calls its main-actor actions; the controller owns the recorder,
//  the snapshot ring, the auto-hide timer and every file that results.
//

import SwiftUI
import UIKit

// MARK: - Placement

/// Where the bar lives and how big its touch targets are.
///
/// Named constants so that moving the bar — if it ever collides with the
/// plotter's own on-screen furniture in the field — is a one-line change.
public enum RecordingControlsPlacement {
    /// Bottom-leading, mirroring the existing top-leading Back button.
    public static let alignment: Alignment = .bottomLeading
    public static let inset: CGFloat = 12
    /// The invisible reveal target when the bar is hidden and not recording.
    public static let hiddenTapTarget = CGSize(width: 88, height: 56)
    public static let autoHideDelay: TimeInterval = 4.0

    // ---- Internal metrics. Changing these changes the dead zone; see the
    //      file header before you do.
    static let barHeight: CGFloat = 60
    static let buttonSide: CGFloat = 44
    /// Fixed so the capsule does not breathe as "0:07" becomes "10:00".
    static let readoutWidth: CGFloat = 104
    static let compactPill = CGSize(width: 96, height: 40)
    /// The shutter flash covers any screen this app can be shown on without
    /// ever asking for `.infinity`. See the file header.
    static let flashSpan: CGFloat = 4_000
    static let stateChange: Animation = .easeInOut(duration: 0.18)
}

// MARK: - The bar

/// The record / elapsed-time / snapshot overlay, plus the shutter flash and
/// the capture toast.
///
/// Attach exactly once, as
/// `.overlay(alignment: RecordingControlsPlacement.alignment) { RecordingControlsBar(capture: capture) }`.
@MainActor
public struct RecordingControlsBar: View {

    @ObservedObject private var capture: MirrorCaptureController

    /// Set only by tapping a toast that carries a file URL. Nothing is ever
    /// auto-presented: a modal appearing by itself over a live helm display is
    /// the wrong behaviour on a boat (§7.3).
    @State private var shareItem: ShareItem?
    /// Brief on-button confirmation for a snapshot, independent of the toast
    /// so the tap feels answered before the JPEG has even been encoded.
    @State private var snapshotConfirmed = false
    @State private var snapshotConfirmTask: Task<Void, Never>?

    public init(capture: MirrorCaptureController) {
        _capture = ObservedObject(wrappedValue: capture)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = capture.toast {
                CaptureToastView(toast: toast) { url in
                    shareItem = ShareItem(url: url)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            controls
        }
        .fixedSize()                                    // content-sized. Never remove.
        .padding(RecordingControlsPlacement.inset)
        .background(ShutterFlash(active: capture.flash))
        .animation(RecordingControlsPlacement.stateChange, value: capture.controlsVisible)
        .animation(RecordingControlsPlacement.stateChange, value: capture.isRecording)
        .animation(.easeInOut(duration: 0.2), value: capture.toast)
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
    }

    // MARK: Three states, all in the same corner

    @ViewBuilder
    private var controls: some View {
        if capture.controlsVisible {
            expandedBar
                .transition(.opacity)
        } else if capture.isRecording {
            compactPill
                .transition(.opacity)
        } else {
            hiddenRevealTarget
        }
    }

    /// ~230 x 60 pt: record button, readout, snapshot button.
    private var expandedBar: some View {
        HStack(spacing: 4) {
            recordButton
            readout
            snapshotButton
        }
        .padding(.horizontal, 8)
        .frame(height: RecordingControlsPlacement.barHeight)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    /// Hidden while recording: a compact `● 0:07` pill that is also the reveal
    /// target, so the elapsed time is never more than a glance away.
    private var compactPill: some View {
        Button {
            capture.revealControls()
        } label: {
            HStack(spacing: 6) {
                PulsingRecordDot()
                Text(RecordingNames.elapsedLabel(capture.elapsed))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: RecordingControlsPlacement.compactPill.width,
                   height: RecordingControlsPlacement.compactPill.height)
            .background(.ultraThinMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(HelmControlButtonStyle())
        .accessibilityLabel("Recording \(RecordingNames.elapsedLabel(capture.elapsed)). Show controls")
    }

    /// Hidden and idle: invisible, and the only thing in this corner that is
    /// not a plotter touch target.
    private var hiddenRevealTarget: some View {
        Button {
            capture.revealControls()
        } label: {
            Color.clear
                .frame(width: RecordingControlsPlacement.hiddenTapTarget.width,
                       height: RecordingControlsPlacement.hiddenTapTarget.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show recording controls")
    }

    // MARK: Bar content

    private var recordButton: some View {
        Button {
            capture.toggleRecording()
            // After the action, so the controller sees the settled recording
            // state when it (re)schedules the auto-hide timer.
            capture.revealControls()
            Haptics.tap()
        } label: {
            ZStack {
                if capture.isRecording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: RecordingControlsPlacement.buttonSide,
                   height: RecordingControlsPlacement.buttonSide)
            .contentShape(Circle())
        }
        .buttonStyle(HelmControlButtonStyle())
        .accessibilityLabel(capture.isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private var readout: some View {
        if capture.isRecording {
            HStack(spacing: 6) {
                PulsingRecordDot()
                Text(RecordingNames.elapsedLabel(capture.elapsed))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: RecordingControlsPlacement.readoutWidth)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording \(RecordingNames.elapsedLabel(capture.elapsed))")
        } else {
            // The free-space check, shown before the user commits to a
            // recording rather than as a refusal afterwards.
            Text(freeSpaceLabel)
                .font(.caption2)
                .foregroundStyle(freeSpaceIsLow ? Color.orange : Color.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: RecordingControlsPlacement.readoutWidth)
                .accessibilityLabel(freeSpaceIsLow
                                    ? "Storage low, \(freeSpaceLabel)"
                                    : freeSpaceLabel)
        }
    }

    private var snapshotButton: some View {
        Button {
            capture.takeSnapshot()
            capture.revealControls()
            confirmSnapshot()
            Haptics.tap()
        } label: {
            Image(systemName: snapshotConfirmed ? "checkmark" : "camera.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(snapshotConfirmed ? Color.green : Color.white)
                .frame(width: RecordingControlsPlacement.buttonSide,
                       height: RecordingControlsPlacement.buttonSide)
                .contentShape(Circle())
        }
        .buttonStyle(HelmControlButtonStyle())
        .animation(.easeInOut(duration: 0.15), value: snapshotConfirmed)
        .accessibilityLabel("Take snapshot")
    }

    // MARK: Helpers

    /// Held for 0.9 s, restarted by a second tap. The toast reports where the
    /// file went; this only says "the tap landed".
    private func confirmSnapshot() {
        snapshotConfirmTask?.cancel()
        snapshotConfirmed = true
        snapshotConfirmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            snapshotConfirmed = false
        }
    }

    private var freeSpaceIsLow: Bool {
        let bytes = capture.freeBytes
        return bytes > 0 && bytes < RecordingLimits.helm.minimumFreeBytesToStart
    }

    /// `MirrorRecorder.availableBytes` reports `Int64.max` when the volume's
    /// capacity is unreadable, and `freeBytes` is 0 until the first refresh.
    /// Neither is a number worth showing.
    private var freeSpaceLabel: String {
        let bytes = capture.freeBytes
        guard bytes > 0, bytes < Int64.max else { return "Ready" }
        return Self.byteFormatter.string(fromByteCount: bytes) + " free"
    }

    @MainActor
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter
    }()

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }
}

// MARK: - Pieces

/// The recording indicator. Only the dot animates: on a moving boat the stop
/// button must never fade out from under a hand reaching for it.
private struct PulsingRecordDot: View {
    var diameter: CGFloat = 8
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: diameter, height: diameter)
            .opacity(dimmed ? 0.35 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .onDisappear { dimmed = false }
            .accessibilityHidden(true)
    }
}

/// The 150 ms white shutter flash.
///
/// Deliberately oversized rather than expanded with `.frame(maxWidth:
/// .infinity)`, and attached through `.background`, which never feeds its
/// child's size back to the parent — so it covers the screen visually while
/// adding exactly nothing to the bar's layout. `.allowsHitTesting(false)`
/// means not one pixel of it is a touch target.
private struct ShutterFlash: View {
    let active: Bool

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: RecordingControlsPlacement.flashSpan,
                   height: RecordingControlsPlacement.flashSpan)
            .opacity(active ? 0.9 : 0)
            .animation(.easeOut(duration: 0.12), value: active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Where the file went. Tappable only when it carries a URL to share.
private struct CaptureToastView: View {
    let toast: CaptureToast
    let onShare: (URL) -> Void

    var body: some View {
        if let url = toast.shareURL {
            Button {
                onShare(url)
            } label: {
                chrome
            }
            .buttonStyle(HelmControlButtonStyle())
            .accessibilityLabel(toast.text)
            .accessibilityHint("Opens the share sheet")
        } else {
            chrome
                .allowsHitTesting(false)     // never a dead zone over the plotter
                .accessibilityLabel(toast.text)
        }
    }

    private var chrome: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(toast.isError ? Color.orange : Color.green)
            Text(toast.text)
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(1)
            if toast.shareURL != nil {
                Image(systemName: "square.and.arrow.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(toast.isError ? Color.orange.opacity(0.55)
                                                 : Color.white.opacity(0.12),
                                   lineWidth: 0.5)
        )
        .contentShape(Capsule())
    }
}

/// Press feedback without the tint and layout surprises of the system styles.
private struct HelmControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A glance at the screen is expensive at the helm; a bump in the hand is not.
private enum Haptics {
    @MainActor
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - Share sheet

/// Share-sheet fallback for a file that stayed in Documents (§7.3). Presented
/// only when the user taps a toast — never automatically.
@MainActor
public struct ShareSheet: UIViewControllerRepresentable {

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url],
                                                  applicationActivities: nil)
        // TARGETED_DEVICE_FAMILY is "1,2". On iPad UIKit routes an activity
        // controller through a popover, and presenting one whose
        // popoverPresentationController has no source view traps immediately.
        // The controller's own view is the one anchor guaranteed to be in the
        // window by the time the presentation happens.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX,
                                        y: controller.view.bounds.maxY,
                                        width: 0,
                                        height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    public func updateUIViewController(_ controller: UIActivityViewController,
                                       context: Context) {
        // Nothing to update: the sheet is rebuilt per presentation.
    }
}
