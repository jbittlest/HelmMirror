//
//  HelmSession.swift
//  HelmMirror
//
//  TCP Helm session against a Garmin MFD on port 51200.
//  Opens an NWConnection, runs the fixed handshake (HELLO / TOKEN / SUBSCRIBE×16 /
//  ACQUIRE), reassembles framed messages, surfaces CONTEXT + the RTSP URL, keeps the
//  stream alive with a 5 s re-subscribe burst, and mirrors touches back to the plotter.
//
//  Depends only on the public API of HelmProtocol.swift (frozen). All byte-level
//  decisions live there; this file is pure transport + lifecycle.
//

import Foundation
import Network

/// Live control session for one chartplotter.
///
/// Lifecycle: `start()` returns an `AsyncStream<HelmInbound>` that yields every inbound
/// message of interest (`.context`, `.rtspURL`, `.event`) and *finishes* on disconnect,
/// handshake timeout, or `stop()`. A stream that finishes without ever yielding a
/// `.context` is the pairing gate: the usual cause is the one-time MFD
/// "View and Control" approval not being set, which the view model maps to
/// `ConnectionState.needsPairingApproval`.
public actor HelmSession {

    // MARK: - Tunables (single source of truth)

    /// Re-subscribe cadence. Ground truth requires ~5 s or the plotter stops streaming
    /// (its hard timeout is ~30 s). Exposed as one named constant so it can be tuned
    /// empirically without hunting through the send path.
    private static let keepaliveInterval: TimeInterval = 5.0

    /// If no CONTEXT arrives within this window the handshake is treated as failed —
    /// almost always because the MFD "View and Control" approval is not set. Finishing
    /// the stream lets the UI prompt for that one-time approval.
    private static let handshakeTimeout: TimeInterval = 8.0

    /// Upper bound for a single NWConnection receive.
    private static let maxReceive = 64 * 1024

    // MARK: - Immutable config

    private let host: String
    private let port: Int
    private let queue = DispatchQueue(label: "com.jimmy.helmmirror.session")

    // MARK: - Mutable state (actor-isolated)

    private var connection: NWConnection?
    private var continuation: AsyncStream<HelmInbound>.Continuation?
    private var keepaliveTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var inBuffer = [UInt8]()
    /// Guards the once-only handshake against a possible `.ready` re-entry.
    private var didHandshake = false

    public private(set) var contextId: UInt32?
    public private(set) var rtspURL: String?

    public init(host: String, port: Int = 51200) {
        self.host = host
        self.port = port
    }

    /// Deterministic fallback, used only if no EVENT (0x1649 subtype 0) URL arrives.
    /// `nonisolated` so callers can read it without awaiting the actor; `host` is an
    /// immutable Sendable `let`, so this is safe.
    public nonisolated var fallbackRTSPURL: String {
        "rtsp://\(host):554/helm_1280x720.h264"
    }

    // MARK: - Lifecycle

    /// Open the connection, run the handshake, and start streaming inbound messages.
    /// Re-entrant: a prior run (if any) is torn down first.
    public func start() -> AsyncStream<HelmInbound> {
        teardown()
        contextId = nil
        rtspURL = nil
        didHandshake = false

        // Build-closure capture: the closure runs synchronously inside the initializer,
        // so `cont` is populated before AsyncStream(...) returns.
        var cont: AsyncStream<HelmInbound>.Continuation!
        let stream = AsyncStream<HelmInbound>(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        cont.onTermination = { @Sendable [weak self] _ in
            // The consumer stopped iterating (or we finished): drop the socket. Does not
            // re-finish the continuation, so there is no teardown/finish recursion.
            Task { await self?.teardown() }
        }

        openConnection()
        scheduleHandshakeTimeout()
        return stream
    }

    /// Close the connection and finish the stream.
    public func stop() { finish() }

    /// Frame and send a TOUCH. No-op until a touch context has been acquired.
    public func sendTouch(_ points: [HelmTouchPoint]) {
        guard let ctx = contextId, let conn = connection else { return }
        send(Helm.touch(ctxId: ctx, points: points), on: conn)
    }

    // MARK: - Connection

    private func openConnection() {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 51200) else {
            finish(); return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                       // low-latency touch echo
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false         // the MFD is a Wi-Fi AP, not an AWDL peer

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state) }
        }
        conn.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !didHandshake else { return }
            didHandshake = true
            armReceive()          // be listening before we speak
            sendHandshake()
        case .failed, .cancelled:
            finish()
        default:
            break                 // .waiting / .preparing may recover; handshakeTimeout backstops it
        }
    }

    /// HELLO, TOKEN(8 random), SUBSCRIBE×16, ACQUIRE — exact order (SPEC §4.3) — then
    /// the periodic keepalive burst. NWConnection preserves send order.
    private func sendHandshake() {
        guard let conn = connection else { return }
        send(Helm.hello(), on: conn)
        send(Helm.token(Self.randomToken()), on: conn)
        send(Helm.subscribeFrames(), on: conn)   // 16 back-to-back 0x1648 frames, one blob
        send(Helm.acquire(), on: conn)
        startKeepalive()
    }

    private func send(_ data: Data, on conn: NWConnection) {
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { Task { await self?.finish() } }   // a dead socket ends the session
        })
    }

    // MARK: - Receive / reassembly

    private func armReceive() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReceive) { [weak self] data, _, isComplete, error in
            Task { await self?.onReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func onReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty { ingest(data) }
        if error != nil || isComplete { finish(); return }
        // Re-arm from inside the actor: exactly one read is ever outstanding, so bytes
        // (and therefore frames) are processed strictly in order.
        armReceive()
    }

    /// Append to the rolling buffer and drain every complete frame.
    private func ingest(_ data: Data) {
        inBuffer.append(contentsOf: data)
        while inBuffer.count >= 8 {
            // Re-sync guard: the envelope magic (bytes 2..3, LE) must be 0xBEEF. The core
            // decoder ignores magic by design, so we validate here and drop a single byte
            // on mismatch to recover from any stream misalignment.
            let magic = UInt16(inBuffer[2]) | (UInt16(inBuffer[3]) << 8)
            if magic != HelmFrame.magic {
                inBuffer.removeFirst(1)
                continue
            }
            guard let (frame, consumed) = HelmFrame.decode(inBuffer) else { break } // need more bytes
            inBuffer.removeFirst(consumed)
            deliver(frame)
        }
    }

    private func deliver(_ frame: HelmFrame) {
        guard let inbound = Helm.parse(frame) else { return }
        switch inbound {
        case .context(let id):
            contextId = id
            handshakeTask?.cancel(); handshakeTask = nil   // handshake reached the touch context
        case .rtspURL(let url):
            rtspURL = url
        case .event:
            break
        }
        continuation?.yield(inbound)
    }

    // MARK: - Keepalive + handshake timeout

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            let ns = UInt64(Self.keepaliveInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                await self?.sendKeepalive()
            }
        }
    }

    private func sendKeepalive() {
        guard let conn = connection else { return }
        send(Helm.subscribeFrames(), on: conn)   // re-subscribe burst keeps the stream alive
    }

    private func scheduleHandshakeTimeout() {
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.handshakeTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.handshakeDeadlineReached()
        }
    }

    private func handshakeDeadlineReached() {
        // No touch context => not authorized. Finish so the view model can surface the
        // one-time MFD "View and Control" approval instructions.
        if contextId == nil { finish() }
    }

    // MARK: - Teardown

    /// Drop the socket + timers without touching the stream continuation. Idempotent.
    private func teardown() {
        keepaliveTask?.cancel(); keepaliveTask = nil
        handshakeTask?.cancel(); handshakeTask = nil
        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        connection = nil
        inBuffer.removeAll(keepingCapacity: false)
    }

    /// Full stop: tear the socket down and finish the stream.
    private func finish() {
        teardown()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Helpers

    private static func randomToken() -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 8)
        for i in t.indices { t[i] = UInt8.random(in: .min ... .max) }
        return t
    }
}
