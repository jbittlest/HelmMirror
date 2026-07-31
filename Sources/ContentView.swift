//
//  ContentView.swift
//  HelmMirror
//
//  UI + view model. Wires the app-layer pieces together per SPEC §7.5:
//
//      GarminDiscovery ──▶ (user taps a plotter)
//                          │
//                          ▼
//        resolve host ──▶ HelmPairing (one-time PUT register + set-role)
//                          │
//                          ▼
//        HelmSession (TCP 51200 handshake) ──▶ CONTEXT + RTSP URL
//                          │
//                          ▼
//                    MirrorPlayerView (RTSP/H.264) ──▶ touches ──▶ HelmSession.sendTouch
//
//  Depends only on the public API of the other app-layer files and on the
//  Foundation-only shared model types from HelmProtocol.swift (same module).
//

import SwiftUI
import Foundation
import Combine

// MARK: - View model

@MainActor
public final class HelmMirrorViewModel: ObservableObject {

    /// Session lifecycle, consumed by `ContentView`.
    @Published public private(set) var state: ConnectionState = .idle
    /// Discovered plotters, mirrored from `GarminDiscovery`.
    @Published public private(set) var plotters: [DiscoveredPlotter] = []
    /// Surfaced from discovery so the UI can prompt to enable Local Network access.
    @Published public private(set) var permissionLikelyDenied: Bool = false

    // ---- Tunables ----------------------------------------------------------

    /// If no CONTEXT arrives within this window, the usual cause is that the
    /// user hasn't set the phone to "View and Control" on the MFD yet, so we
    /// transition to `.needsPairingApproval` (SPEC §7.3 pairing gate).
    private static let handshakeTimeout: TimeInterval = 8.0
    /// After CONTEXT, wait this long for the authoritative EVENT (subtype 0)
    /// RTSP URL before falling back to the deterministic URL (SPEC §4.3 step 6).
    private static let urlFallbackDelay: TimeInterval = 1.0

    /// The ActiveCaptain user name that shows up on the plotter.
    private static let deviceName = "HelmMirror"
    /// UserDefaults key for the STABLE device UUID (SPEC §4.10: persist it so
    /// repeat runs don't spawn new ActiveCaptain users).
    private static let deviceIdKey = "HelmMirror.deviceIdentifier"

    // ---- Collaborators -----------------------------------------------------

    private let discovery = GarminDiscovery()
    private var session: HelmSession?

    // ---- Task bookkeeping --------------------------------------------------

    private var connectTask: Task<Void, Never>?
    private var handshakeWatchdog: Task<Void, Never>?
    private var urlFallbackTimer: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// The plotter we're currently connecting to, resolved (host filled in) so
    /// that Retry-after-approval can re-open the session without re-resolving.
    private var activePlotter: DiscoveredPlotter?
    /// True once we actually reached `.streaming` in the current attempt — lets
    /// us distinguish "dropped mid-stream" from "never authorized".
    private var didStream = false
    /// True once CONTEXT arrived, i.e. the plotter authorized us. A drop after
    /// this point is a transient connection failure, NOT a missing approval —
    /// without this we'd wrongly tell the user to re-approve on the MFD.
    private var gotContext = false

    /// Ordered, single-consumer channel for outbound touches. Every batch goes
    /// through this one stream so press/move/release samples reach the plotter
    /// in the order the finger produced them. Spawning a Task per touch would
    /// let independent Tasks race onto the session actor and reorder a drag.
    private var touchChannel: AsyncStream<[HelmTouchPoint]>.Continuation?
    private var touchPumpTask: Task<Void, Never>?

    /// Stable per-install identity used for pairing.
    private let deviceId: String

    public init() {
        // Load or mint the stable device identifier.
        if let saved = UserDefaults.standard.string(forKey: Self.deviceIdKey) {
            deviceId = saved
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: Self.deviceIdKey)
            deviceId = fresh
        }

        // Mirror discovery's published state onto our own (both @MainActor).
        discovery.$plotters
            .sink { [weak self] in self?.plotters = $0 }
            .store(in: &cancellables)
        discovery.$permissionLikelyDenied
            .sink { [weak self] in self?.permissionLikelyDenied = $0 }
            .store(in: &cancellables)
    }

    // MARK: Discovery

    public func startDiscovery() {
        discovery.start()
        switch state {
        case .idle, .disconnected:
            state = .discovering
        default:
            break   // don't disturb an in-flight connect or a live stream
        }
    }

    // MARK: Connect flow

    /// Resolve → pair (idempotent) → open session → drive `state`, start video on URL.
    public func connect(to plotter: DiscoveredPlotter) {
        connectTask?.cancel()
        teardownSession()
        activePlotter = plotter
        didStream = false
        gotContext = false
        state = .connecting
        connectTask = Task { [weak self] in
            await self?.runConnect(plotter)
        }
    }

    /// User confirmed they set the plotter to "View and Control" — retry the session.
    public func retryAfterApproval() {
        guard let plotter = activePlotter else { startDiscovery(); return }
        connect(to: plotter)
    }

    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        teardownSession()
        didStream = false
        gotContext = false
        state = .discovering
        discovery.start()   // keep browsing so the list repopulates
    }

    /// Forward normalized touches from the mirror view to the live session.
    /// Non-blocking: the batch is queued on an ordered channel drained by a
    /// single pump task, which preserves gesture order on the wire.
    public func sendTouch(_ points: [HelmTouchPoint]) {
        touchChannel?.yield(points)
    }

    /// Start the single consumer that serializes touch delivery for `session`.
    private func startTouchPump(for session: HelmSession) {
        stopTouchPump()
        let (stream, continuation) = { () -> (AsyncStream<[HelmTouchPoint]>, AsyncStream<[HelmTouchPoint]>.Continuation) in
            var cont: AsyncStream<[HelmTouchPoint]>.Continuation!
            let s = AsyncStream<[HelmTouchPoint]> { cont = $0 }
            return (s, cont)
        }()
        touchChannel = continuation
        touchPumpTask = Task { [weak session] in
            for await batch in stream {
                if Task.isCancelled { break }
                guard let session else { break }
                await session.sendTouch(batch)
            }
        }
    }

    private func stopTouchPump() {
        touchChannel?.finish()
        touchChannel = nil
        touchPumpTask?.cancel()
        touchPumpTask = nil
    }

    // MARK: - Connect implementation

    private func runConnect(_ plotter: DiscoveredPlotter) async {
        // 1. Resolve a concrete host (prefer a ".local" name; see GarminDiscovery).
        var resolved = plotter
        if resolved.host == nil, let r = await discovery.resolve(plotter) {
            resolved = r
        }
        guard !Task.isCancelled else { return }
        guard let host = resolved.host else {
            state = .failed(reason: "Couldn't find the plotter on the network. "
                            + "Make sure your phone is joined to the plotter's Wi-Fi.")
            return
        }
        activePlotter = resolved

        // 2. Pair. This is idempotent (a stable device UUID means no new
        //    ActiveCaptain user), so failures here are non-fatal: the real
        //    authorization gate is the human "View and Control" step, which the
        //    session below will surface as .needsPairingApproval if missing.
        do {
            let pairing = HelmPairing(host: host, port: resolved.pairingPort)
            try await pairing.pair(deviceId: deviceId,
                                   deviceName: Self.deviceName,
                                   role: "owner")
        } catch {
            // Intentionally continue — see comment above.
        }
        guard !Task.isCancelled else { return }

        // 3. Open the Helm TCP session and consume inbound messages.
        state = .handshaking
        let session = HelmSession(host: host, port: resolved.helmPort)
        self.session = session
        startTouchPump(for: session)
        startHandshakeWatchdog()

        let stream = await session.start()
        for await msg in stream {
            if Task.isCancelled { break }
            handleInbound(msg, fallbackURL: session.fallbackRTSPURL)
        }

        // Stream finished (disconnect or failure).
        guard !Task.isCancelled else { return }
        cancelTimers()
        stopTouchPump()
        if didStream {
            state = .disconnected
        } else if gotContext {
            // CONTEXT arrived, so the plotter DID authorize us — we just lost the
            // link before video started. Retryable; don't send the user off to
            // re-approve something that already succeeded.
            state = .failed(reason: "Lost the connection to the plotter before video started. "
                            + "Check you're still on its Wi-Fi, then try again.")
        } else if !isAwaitingApproval {
            // Never authorized and the watchdog didn't already flip us — the
            // plotter dropped us because the phone isn't set to View and Control.
            state = .needsPairingApproval
        }
    }

    private func handleInbound(_ msg: HelmInbound, fallbackURL: String) {
        switch msg {
        case .context:
            // A touch context means the plotter authorized us: cancel the
            // approval watchdog and wait briefly for the authoritative URL.
            gotContext = true
            handshakeWatchdog?.cancel()
            handshakeWatchdog = nil
            startURLFallbackTimer(fallbackURL: fallbackURL)

        case .rtspURL(let url):
            cancelTimers()
            beginStreaming(url)

        case .event:
            break   // subtype 1 (inline H.264 + name) etc. — not used by v1
        }
    }

    private func beginStreaming(_ url: String) {
        didStream = true
        state = .streaming(rtspURL: playableURL(url))
    }

    /// The plotter hands back its video as an mDNS name
    /// (`rtsp://garmin-j6-kraken-1234.local:554/…`). VLC on iOS resolves names
    /// itself and does not do mDNS, so that URL opens and then never delivers a
    /// frame. Discovery already resolved the plotter's numeric address, so swap
    /// it in. Falls back to the original URL if anything doesn't parse.
    private func playableURL(_ url: String) -> String {
        // 1. Prefer the address discovery already resolved for this plotter.
        if let host = activePlotter?.host,
           Helm.isNumericIPv4(host),
           let rewritten = Helm.rewritingHost(of: url, to: host) {
            return rewritten
        }
        // 2. Otherwise resolve the URL's own host with the system resolver, which
        //    does understand .local even though VLC does not.
        if let urlHost = Helm.hostComponent(of: url),
           !Helm.isNumericIPv4(urlHost),
           let numeric = GarminDiscovery.numericIPv4(for: urlHost),
           let rewritten = Helm.rewritingHost(of: url, to: numeric) {
            return rewritten
        }
        return url
    }

    // MARK: Timers

    private func startHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.handshakeTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            switch self.state {
            case .streaming, .needsPairingApproval, .failed:
                return   // already resolved one way or another
            default:
                self.state = .needsPairingApproval
                self.teardownSession()
            }
        }
    }

    private func startURLFallbackTimer(fallbackURL: String) {
        urlFallbackTimer?.cancel()
        urlFallbackTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.urlFallbackDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if case .streaming = self.state { return }
            self.beginStreaming(fallbackURL)
        }
    }

    private func cancelTimers() {
        handshakeWatchdog?.cancel(); handshakeWatchdog = nil
        urlFallbackTimer?.cancel(); urlFallbackTimer = nil
    }

    private var isAwaitingApproval: Bool {
        if case .needsPairingApproval = state { return true }
        return false
    }

    private func teardownSession() {
        cancelTimers()
        stopTouchPump()
        let s = session
        session = nil
        Task { await s?.stop() }
    }
}

// MARK: - Root view

public struct ContentView: View {
    @StateObject private var vm = HelmMirrorViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .onAppear { vm.startDiscovery() }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle, .discovering, .disconnected:
            DiscoveryScreen(plotters: vm.plotters,
                            permissionDenied: vm.permissionLikelyDenied,
                            onSelect: vm.connect)

        case .connecting:
            StatusScreen(symbol: "wifi",
                         title: "Connecting…",
                         message: "Reaching the chartplotter.")

        case .handshaking:
            StatusScreen(symbol: "antenna.radiowaves.left.and.right",
                         title: "Starting the mirror…",
                         message: "Negotiating with the helm.")

        case .needsPairingApproval:
            PairingApprovalScreen(onRetry: vm.retryAfterApproval,
                                  onBack: vm.disconnect)

        case .streaming(let rtspURL):
            MirrorScreen(rtspURL: rtspURL,
                         onTouch: vm.sendTouch,
                         onBack: vm.disconnect)

        case .failed(let reason):
            FailureScreen(reason: reason,
                          permissionDenied: vm.permissionLikelyDenied,
                          onRetry: vm.retryAfterApproval,
                          onBack: vm.disconnect)
        }
    }
}

// MARK: - Discovery screen

private struct DiscoveryScreen: View {
    let plotters: [DiscoveredPlotter]
    let permissionDenied: Bool
    let onSelect: (DiscoveredPlotter) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            if permissionDenied && plotters.isEmpty {
                LocalNetworkBanner()
                Spacer()
            } else if plotters.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Searching for your chartplotter…")
                        .foregroundStyle(.secondary)
                    Text("Join the plotter's Wi-Fi network, then wait a moment.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                if permissionDenied { LocalNetworkBanner() }
                List(plotters) { plotter in
                    Button { onSelect(plotter) } label: {
                        PlotterRow(plotter: plotter)
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Image(systemName: "sailboat.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("HelmMirror")
                .font(.title2.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

private struct PlotterRow: View {
    let plotter: DiscoveredPlotter

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "display")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(plotter.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(plotter.host ?? "resolving…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct LocalNetworkBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("No plotter found yet. Check your phone is joined to the plotter's Wi-Fi — "
     + "and if it is, make sure Local Network is enabled in Settings ▸ HelmMirror.")
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Transient status screen

private struct StatusScreen: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pairing-approval instructions

private struct PairingApprovalScreen: View {
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("One-time approval needed")
                .font(.title2.weight(.semibold))

            VStack(spacing: 8) {
                Text("On the chartplotter, allow this phone to control the helm:")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Settings ▸ Communications ▸ Wi-Fi Network ▸ Wi-Fi Devices")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                Text("Set this phone to **View and Control**.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button(role: .cancel, action: onBack) {
                    Text("Back")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onRetry) {
                    Text("I've approved it — Retry")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 520)
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Failure screen

private struct FailureScreen: View {
    let reason: String
    let permissionDenied: Bool
    let onRetry: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.yellow)

            Text("Connection problem")
                .font(.title2.weight(.semibold))

            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            if permissionDenied {
                Text("No plotter found yet. Check your phone is joined to the plotter's Wi-Fi — "
     + "and if it is, make sure Local Network is enabled in Settings ▸ HelmMirror.")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                Button(role: .cancel, action: onBack) {
                    Text("Back")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onRetry) {
                    Text("Retry")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 520)
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mirror (live video + touch) screen

private struct MirrorScreen: View {
    let rtspURL: String
    let onTouch: ([HelmTouchPoint]) -> Void
    let onBack: () -> Void

    @State private var playback: MirrorPlaybackState = .opening
    @State private var everPlayed = false
    @State private var timedOut = false
    @State private var attemptIndex = 0
    @ObservedObject private var diagnostics = MirrorDiagnostics.shared

    /// How long to give one attempt before moving to the next combination.
    private static let attemptTimeout: TimeInterval = 8

    private var attempts: [MirrorAttempt] { MirrorAttempt.ladder(for: rtspURL) }
    private var attempt: MirrorAttempt {
        attempts.indices.contains(attemptIndex) ? attempts[attemptIndex]
                                                : MirrorAttempt(url: rtspURL, useTCP: false)
    }
    private var exhausted: Bool { attemptIndex >= attempts.count - 1 }

    private var showOverlay: Bool { !playback.isPlaying }

    /// Move to the next URL/transport combination, if one is left.
    private func nextAttempt() {
        guard !everPlayed, attemptIndex < attempts.count - 1 else { return }
        attemptIndex += 1
        playback = .opening
        timedOut = false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Present at 16:9 so the content rect equals the view bounds and
            // MirrorPlayerView's nx = x/width, ny = y/height are exact (SPEC §7.4).
            MirrorPlayerView(rtspURL: attempt.url, useTCP: attempt.useTCP, onTouch: onTouch) { state in
                playback = state
                if state.isPlaying { everPlayed = true; timedOut = false }
                // live555 can fail in ways the API does not explain; just move on
                // to the next URL/transport rather than stopping at the first one.
                if state == .failed || state == .ended { nextAttempt() }
            }
            .id(attempt)   // rebuild the player when the attempt changes
            .aspectRatio(1280.0 / 720.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A black rectangle with no explanation is the worst possible failure
            // mode — it looks identical to a crash. Always say what is happening.
            if showOverlay {
                VStack(spacing: 14) {
                    if (playback == .failed || playback == .ended || timedOut) && exhausted {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.yellow)
                    } else {
                        ProgressView().controlSize(.large).tint(.white)
                    }

                    Text(timedOut && !everPlayed && exhausted
                         ? "No video arrived from the plotter"
                         : playback.message)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("Attempt \(attemptIndex + 1) of \(attempts.count) · \(attempt.useTCP ? "TCP" : "UDP")")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))

                    Text(attempt.url)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    // On-screen diagnostics: the phone is usually not tethered
                    // when this fails, so the facts have to be readable here.
                    if !diagnostics.text.isEmpty {
                        ScrollView {
                            Text(diagnostics.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 150)
                        .padding(10)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 20)
                    }

                    if (playback == .failed || playback == .ended || timedOut) && exhausted {
                        Button("Back to plotter list", action: onBack)
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 4)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.82))
                .ignoresSafeArea()
            }
        }
        // Always reachable, and legible against black — the old faint chevron on a
        // black screen looked like the app had simply hung.
        .overlay(alignment: .topLeading) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.backward")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(12)
            .tint(.white)
        }
        // One timer per attempt: if this combination produces nothing in time,
        // stop waiting on it and try the next.
        .task(id: attempt) {
            try? await Task.sleep(nanoseconds: UInt64(Self.attemptTimeout * 1_000_000_000))
            guard !Task.isCancelled, !everPlayed else { return }
            timedOut = true
            nextAttempt()
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
}
