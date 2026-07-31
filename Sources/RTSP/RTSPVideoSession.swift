//
//  RTSPVideoSession.swift
//  HelmMirror
//
//  The glue that turns "a URL" into "pictures". It owns, in order:
//
//    RTSPClient  →  RTPUDPTransport (or `$`-interleaved frames from the client)
//                →  RTPReorderBuffer  →  H264Depacketizer  →  callbacks
//
//  and translates the whole thing into the six `MirrorPlaybackState` cases the UI
//  already knows about.
//
//  Three responsibilities that are easy to miss and expensive to omit:
//
//    1. **Transport fallback.** UDP first, exactly one automatic retry over
//       interleaved TCP if SETUP is refused or no RTP shows up. Once only — a
//       loop here would blow the outer 8 s attempt budget in `ContentView`.
//    2. **Keyframe gating.** After any loss, decode failure or restart, every
//       access unit is dropped until a clean IDR arrives. Feeding a decoder
//       mid-GOP is what produces the green-smear failure mode.
//    3. **Logging.** Every RTSP line reaches `MirrorDiagnostics.shared`, because
//       the on-screen log is how this thing gets debugged at the helm with no Mac
//       in sight (SPEC §11).
//
//  Threading: one serial queue owns the client, the transport, the reorder buffer
//  and the depacketizer, and `onParameterSets` / `onAccessUnit` are delivered on
//  it. `onState` is always delivered on main.
//
//  Frozen interface and timings: SPEC §5.4.
//

import Foundation
import UIKit

public final class RTSPVideoSession {

    // MARK: - Frozen timings (SPEC §5.4)

    /// After PLAY, no RTP at all ⇒ transport fallback or failure.
    private static let rtpArrivalTimeout: TimeInterval = 3.0
    /// After playing, no RTP ⇒ `.stalled`.
    private static let stallTimeout: TimeInterval = 3.0
    /// After `.stalled` with no recovery ⇒ `.ended`.
    private static let deadTimeout: TimeInterval = 10.0
    /// How often the watchdog checks the three deadlines above.
    private static let tickInterval: TimeInterval = 0.5
    /// Loss is bursty; one line per second is plenty and keeps the 40-line ring
    /// from swallowing the handshake it exists to show.
    private static let dropLogInterval: TimeInterval = 1.0

    // MARK: - Configuration

    private let url: String
    private let preferTCP: Bool
    private let queue = DispatchQueue(label: "com.jimmy.helmmirror.rtsp.session")

    /// Delivered on MAIN.
    public var onState: ((MirrorPlaybackState) -> Void)?
    /// Delivered on the session's serial video queue.
    public var onParameterSets: ((H264ParameterSets) -> Void)?
    /// Delivered on the session's serial video queue.
    public var onAccessUnit: ((H264AccessUnit) -> Void)?

    // MARK: - State (queue-confined unless noted)

    private var client: RTSPClient?
    private var transport: RTPUDPTransport?
    private var reorder = RTPReorderBuffer()
    private var depacketizer = H264Depacketizer()

    private var activeMode: RTSPTransportMode = .udp
    private var rtpChannel: UInt8 = 0
    /// One shot per `start()`, per SPEC §5.4 step 6.
    private var didFallback = false

    private var state: MirrorPlaybackState = .opening
    private var everPlayed = false
    private var needsKeyframe = true

    private var rtpPacketCount = 0
    private var playedAt: Date?
    private var lastRTPAt: Date?
    private var stalledAt: Date?
    private var lastDropLogAt: Date?

    /// Bumped on every (re)arm; a tick whose generation is stale does nothing.
    private var tickGeneration = 0

    /// Set from any thread. `running` gates the pipeline, `stopped` is permanent.
    private let lifecycleLock = NSLock()
    private var running = false
    private var stopped = false

    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: - Init

    /// `preferTCP == false` means "UDP first, automatic one-shot fallback to
    /// interleaved TCP". `true` means "go straight to interleaved TCP".
    public init(url: String, preferTCP: Bool) {
        self.url = url
        self.preferTCP = preferTCP
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        client?.stop()
        transport?.stop()
    }

    // MARK: - Lifecycle

    public func start() {
        lifecycleLock.lock()
        let alreadyRunning = running || stopped
        if !alreadyRunning { running = true }
        lifecycleLock.unlock()
        guard !alreadyRunning else { return }

        observeAppLifecycle()
        queue.async { [weak self] in
            guard let self else { return }
            self.didFallback = false
            self.beginAttempt(mode: self.preferTCP ? .tcpInterleaved : .udp)
        }
    }

    /// Idempotent; after it returns no callback fires.
    public func stop() {
        lifecycleLock.lock()
        let alreadyStopped = stopped
        stopped = true
        running = false
        lifecycleLock.unlock()
        guard !alreadyStopped else { return }

        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()

        // `stopped` above is what actually silences the session: every callback
        // path checks it, synchronously, before touching a closure. The sockets
        // are then torn down on the queue that owns them — reading `client` and
        // `transport` from the caller's thread would be a plain data race, and
        // one queue hop is not worth it.
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownAttempt()
        }
    }

    private var isStopped: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return stopped
    }

    /// Network sockets do not survive suspension, so the session is torn down on
    /// the way out and rebuilt from scratch on the way back in. Anything cleverer
    /// (reconnect, resume) fails silently and leaves a black rectangle.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.suspendForBackground()
            })
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.resumeFromForeground()
            })
    }

    private func suspendForBackground() {
        guard !isStopped else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            MirrorDiagnostics.shared.log("background: session suspended")
            self.teardownAttempt()
        }
    }

    private func resumeFromForeground() {
        guard !isStopped else { return }
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            MirrorDiagnostics.shared.log("foreground: restarting session")
            self.didFallback = false
            // A decoder resumed from the background needs a fresh IDR.
            self.needsKeyframe = true
            self.beginAttempt(mode: self.preferTCP ? .tcpInterleaved : .udp)
        }
    }

    // MARK: - Attempts

    /// Build and start one client + transport pair. Always preceded by a
    /// `teardownAttempt()` so no two attempts ever share buffers.
    private func beginAttempt(mode requested: RTSPTransportMode) {
        guard !isStopped else { return }
        teardownAttempt()

        var mode = requested
        var clientRTPPort: UInt16?

        if mode == .udp {
            if let udp = RTPUDPTransport(queue: queue, attempts: 8) {
                udp.onLog = { line in MirrorDiagnostics.shared.log(line) }
                udp.onRTP = { [weak self] data in self?.handleRTP(data) }
                transport = udp
                clientRTPPort = udp.ports.rtp
                udp.start()
            } else {
                // A normal outcome, not an error: fall straight through to TCP.
                MirrorDiagnostics.shared.log("udp bind failed -> TCP")
                mode = .tcpInterleaved
                didFallback = true
            }
        }

        activeMode = mode
        set(.opening)

        let client = RTSPClient(url: url, mode: mode, clientRTPPort: clientRTPPort, queue: queue)
        client.delegate = self
        self.client = client
        client.start()
    }

    /// Drop the client, the sockets and every byte of decode state. Keeps
    /// `everPlayed`, `didFallback` and the published state.
    private func teardownAttempt() {
        tickGeneration &+= 1
        client?.delegate = nil
        client?.stop()
        client = nil
        transport?.stop()
        transport = nil
        reorder.reset()
        depacketizer.reset()
        rtpPacketCount = 0
        playedAt = nil
        lastRTPAt = nil
        stalledAt = nil
        needsKeyframe = true
    }

    /// The one-shot UDP → interleaved-TCP retry. Returns false when the caller
    /// must report a real failure instead.
    private func fallbackToTCP(reason: String) -> Bool {
        guard !preferTCP, !didFallback, activeMode == .udp, !isStopped else { return false }
        didFallback = true
        MirrorDiagnostics.shared.log(reason)
        beginAttempt(mode: .tcpInterleaved)
        return true
    }

    // MARK: - RTP path

    /// One RTP datagram or one `$` frame. Always on `queue`.
    private func handleRTP(_ data: Data) {
        guard !isStopped else { return }

        rtpPacketCount += 1
        lastRTPAt = Date()

        guard let packet = RTPPacket.parse(data) else { return }

        let output = reorder.push(packet)
        var lostBefore = output.lost
        for delivered in output.packets {
            // The gap belongs to the head of the batch only.
            let events = depacketizer.push(delivered, lostBefore: lostBefore)
            lostBefore = 0
            for event in events { handle(event) }
        }
    }

    private func handle(_ event: H264Depacketizer.Event) {
        switch event {
        case .parameterSets(let sets):
            onParameterSets?(sets)

        case .accessUnit(let unit):
            // Keyframe gating (SPEC §5.4 step 5): a decoder started mid-GOP, or
            // fed a unit with holes in it, renders a green smear rather than
            // failing, so the only safe move is to wait for a clean IDR.
            if unit.isCorrupt {
                needsKeyframe = true
                return
            }
            if needsKeyframe {
                guard unit.isKeyframe else { return }
                needsKeyframe = false
            }
            onAccessUnit?(unit)
            everPlayed = true
            stalledAt = nil
            set(.playing)

        case .dropped(let reason):
            needsKeyframe = true
            let now = Date()
            if let last = lastDropLogAt, now.timeIntervalSince(last) < Self.dropLogInterval { return }
            lastDropLogAt = now
            MirrorDiagnostics.shared.log("rtp: \(reason)")
        }
    }

    // MARK: - Watchdog

    private func scheduleTick() {
        tickGeneration &+= 1
        let generation = tickGeneration
        queue.asyncAfter(deadline: .now() + Self.tickInterval) { [weak self] in
            guard let self, generation == self.tickGeneration, !self.isStopped else { return }
            self.tick()
            // `tick()` may have torn the attempt down and started another, which
            // arms its own timer; only re-arm when this generation still owns it.
            guard generation == self.tickGeneration, !self.isStopped else { return }
            self.scheduleTick()
        }
    }

    private func tick() {
        guard let playedAt else { return }
        let now = Date()

        // 1. PLAY succeeded but not one packet arrived: wrong transport.
        if rtpPacketCount == 0 {
            guard now.timeIntervalSince(playedAt) >= Self.rtpArrivalTimeout else { return }
            if fallbackToTCP(reason: "no RTP over UDP -> retrying interleaved TCP") { return }
            MirrorDiagnostics.shared.log("err: no RTP received after PLAY")
            fail()
            return
        }

        // 2. RTP was flowing and stopped.
        guard let lastRTPAt else { return }
        let silence = now.timeIntervalSince(lastRTPAt)

        if state == .stalled {
            if let stalledAt, now.timeIntervalSince(stalledAt) >= Self.deadTimeout {
                MirrorDiagnostics.shared.log("rtp: silent for \(Int(silence))s — ending")
                teardownAttempt()
                set(.ended)
            }
            return
        }

        if everPlayed, silence >= Self.stallTimeout {
            stalledAt = now
            MirrorDiagnostics.shared.log("rtp: stalled")
            set(.stalled)
        }
    }

    // MARK: - State publishing

    private func set(_ next: MirrorPlaybackState) {
        guard state != next, !isStopped else { return }
        state = next
        let sink = onState
        // Re-checked inside the hop as well: `stop()` can land between the guard
        // above and this block running, and "after stop() no callback fires" is
        // part of the contract (SPEC §5.4).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            sink?(next)
        }
    }

    private func fail() {
        teardownAttempt()
        set(.failed)
    }
}

// MARK: - RTSPClientDelegate

extension RTSPVideoSession: RTSPClientDelegate {

    public func rtspClient(_ client: RTSPClient, didLog line: String) {
        // SPEC §11: the handshake on screen is a deliverable, not a nicety.
        MirrorDiagnostics.shared.log(line)
    }

    public func rtspClient(_ client: RTSPClient, didPlay setup: RTSPMediaSetup) {
        guard !isStopped, client === self.client else { return }

        activeMode = setup.mode
        rtpChannel = setup.rtpChannel

        // The plotter may only send parameter sets in band (SPEC §9.4), but when
        // the SDP carries them the format description can be built immediately —
        // which means the very first IDR is displayable instead of discarded.
        if !setup.track.sps.isEmpty, !setup.track.pps.isEmpty {
            let sets = H264ParameterSets(sps: setup.track.sps, pps: setup.track.pps)
            depacketizer = H264Depacketizer(initial: sets)
            onParameterSets?(sets)
        }

        playedAt = Date()
        lastRTPAt = nil
        rtpPacketCount = 0
        set(.buffering)
        scheduleTick()
    }

    public func rtspClient(_ client: RTSPClient, didReceiveInterleaved channel: UInt8, payload: Data) {
        guard !isStopped, client === self.client else { return }
        // RTCP arrives on rtpChannel + 1 and is discarded, exactly as in UDP mode.
        guard channel == rtpChannel else { return }
        handleRTP(payload)
    }

    public func rtspClient(_ client: RTSPClient, didFailWith error: RTSPClientError) {
        guard !isStopped, client === self.client else { return }
        MirrorDiagnostics.shared.log("err: \(error.description)")

        // A refused transport is the other documented trigger for the one-shot
        // retry — the plotter is alive, it just will not speak this dialect.
        if case .transportRejected = error,
           fallbackToTCP(reason: "\(error.description) -> retrying interleaved TCP") {
            return
        }
        fail()
    }

    public func rtspClientDidEnd(_ client: RTSPClient) {
        guard !isStopped, client === self.client else { return }
        MirrorDiagnostics.shared.log("rtsp: connection closed")
        teardownAttempt()
        set(everPlayed ? .ended : .failed)
    }
}
