//
//  HelmLink.swift
//  helmbridge
//
//  The live Helm session: one TCP connection to the plotter on :51200, the
//  four-step handshake, a 5 second keepalive, inbound frame reassembly and
//  outbound touch injection.
//
//  All mutable state lives on the actor. Network.framework hands us its
//  callbacks on a private DispatchQueue, so every callback immediately hops
//  back onto the actor and only Sendable values (Data, Bool, String) cross
//  that boundary.
//

import Foundation
import Network
import HelmProtocol

actor HelmLink {

    // MARK: - Tunables

    /// Budget for connect + handshake + first CONTEXT frame.
    private static let handshakeTimeout: TimeInterval = 12.0
    /// The plotter stops streaming if it does not see a subscribe burst this often.
    private static let keepaliveInterval: TimeInterval = 5.0
    /// A frame claiming more than this is a stream desync, not a real frame.
    private static let maxPayloadBytes = 4 << 20      // 4 MiB
    /// Hard cap on the reassembly buffer, so a desync can never grow without bound.
    private static let maxBufferBytes = 8 << 20       // 8 MiB
    private static let receiveChunk = 64 * 1024

    // MARK: - Configuration

    private let host: String
    private let port: Int
    private let queue = DispatchQueue(label: "com.helmmirror.helmlink")

    // MARK: - State

    private enum Phase {
        case idle          // nothing open yet, or a dropped link waiting to be retried
        case connecting
        case ready
        case closed        // stop() was called; terminal
    }

    private var phase: Phase = .idle
    private var connection: NWConnection?
    /// Bumped whenever we abandon a connection, so callbacks from an old
    /// NWConnection can be recognised and ignored.
    private var generation = 0
    private var handshakeStarted = false

    private var inbound: [UInt8] = []
    private var ctxId: UInt32?
    private var keepalive: Task<Void, Never>?
    /// Last reason Network.framework gave for being unable to connect; folded
    /// into the timeout error so the caller can tell the user something useful.
    private var lastWaitReason: String?

    /// Authoritative RTSP URL, once the plotter has announced one (EVENT subtype 0).
    private(set) var rtspURL: String?

    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var contextWaiters: [CheckedContinuation<Void, Error>] = []
    private var rtspWaiters: [CheckedContinuation<String?, Never>] = []

    // MARK: - Life cycle

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Connects, performs the handshake and returns once the plotter has sent a
    /// CONTEXT frame. Throws `HelmError.connectionFailed` if the plotter cannot
    /// be reached and `HelmError.handshakeTimeout` if it answers but never grants
    /// a context — which is what "the human has not approved this device yet"
    /// looks like on the wire.
    ///
    /// Safe to call again after a timeout: the connection is left up, so a late
    /// approval on the plotter is picked up by the next call.
    func start() async throws {
        switch phase {
        case .closed:
            throw HelmError.notConnected
        case .idle:
            openConnection()
        case .connecting, .ready:
            break
        }

        let began = Date()
        try await waitUntilReady(timeout: Self.handshakeTimeout)

        if !handshakeStarted {
            handshakeStarted = true
            receiveNext(generation)
            do {
                try await sendHandshake()
            } catch {
                handshakeStarted = false
                throw error
            }
            startKeepalive()
        }

        if ctxId != nil { return }
        let remaining = Self.handshakeTimeout - Date().timeIntervalSince(began)
        try await waitForContext(timeout: max(1.0, remaining))
    }

    /// Waits for the plotter's authoritative RTSP URL. Returns nil on timeout;
    /// the caller is expected to fall back to the well-known URL.
    func waitForRTSPURL(timeout: TimeInterval) async -> String? {
        if let rtspURL { return rtspURL }
        guard phase != .closed else { return nil }

        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: HelmLink.nanoseconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.expireRTSPWaiters()
        }
        defer { timer.cancel() }

        return await withCheckedContinuation { continuation in
            rtspWaiters.append(continuation)
        }
    }

    /// Sends one single-finger touch. No-op until CONTEXT has arrived — the
    /// plotter discards touches that carry an unknown context id.
    func sendTouch(nx: Double, ny: Double, down: Bool) async {
        guard phase == .ready, let ctxId, let connection else { return }
        let point = HelmTouchPoint(trackId: 0, nx: nx, ny: ny, down: down)
        connection.send(content: Helm.touch(ctxId: ctxId, points: [point]),
                        completion: .contentProcessed { _ in })
    }

    /// Tears the session down for good.
    func stop() async {
        guard phase != .closed else { return }
        phase = .closed
        generation += 1
        keepalive?.cancel()
        keepalive = nil
        handshakeStarted = false
        inbound.removeAll()
        closeConnection()
        resumeReadyWaiters(throwing: HelmError.notConnected)
        resumeContextWaiters(throwing: HelmError.notConnected)
        expireRTSPWaiters()
    }

    // MARK: - Connection

    private func openConnection() {
        generation += 1
        let gen = generation

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                                  // touches must not wait on Nagle
        tcp.connectionTimeout = Int(Self.handshakeTimeout)
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = Int(Self.keepaliveInterval)
        let parameters = NWParameters(tls: nil, tcp: tcp)

        let conn = NWConnection(host: Self.endpointHost(host),
                                port: Self.endpointPort(port),
                                using: parameters)
        connection = conn
        phase = .connecting
        lastWaitReason = nil

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.connectionBecameReady(gen) }
            case .waiting(let error):
                let reason = Self.describe(error)
                Task { await self.connectionIsWaiting(gen, reason: reason) }
            case .failed(let error):
                let reason = Self.describe(error)
                Task { await self.connectionDropped(gen, reason: reason) }
            case .cancelled:
                Task { await self.connectionDropped(gen, reason: "the connection was closed") }
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func connectionBecameReady(_ gen: Int) {
        guard gen == generation, phase == .connecting else { return }
        phase = .ready
        lastWaitReason = nil
        resumeReadyWaiters(throwing: nil)
    }

    private func connectionIsWaiting(_ gen: Int, reason: String) {
        guard gen == generation else { return }
        lastWaitReason = reason
    }

    /// The link died on its own (not via `stop()`). Drop back to `.idle` so a
    /// later `start()` can rebuild it from scratch.
    private func connectionDropped(_ gen: Int, reason: String) {
        guard gen == generation, phase != .closed else { return }
        generation += 1
        phase = .idle
        handshakeStarted = false
        ctxId = nil
        inbound.removeAll()
        keepalive?.cancel()
        keepalive = nil
        closeConnection()

        let error = HelmError.connectionFailed(reason)
        resumeReadyWaiters(throwing: error)
        resumeContextWaiters(throwing: error)
        expireRTSPWaiters()
    }

    private func closeConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: - Handshake

    private func sendHandshake() async throws {
        // Order matters: HELLO, TOKEN, the 16 SUBSCRIBE frames, then ACQUIRE.
        try await send(Helm.hello())
        try await send(Helm.token((0..<8).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }))
        try await send(Helm.subscribeFrames())
        try await send(Helm.acquire())
    }

    private func send(_ data: Data) async throws {
        guard let connection, phase == .ready else { throw HelmError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: HelmError.connectionFailed(Self.describe(error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func startKeepalive() {
        keepalive?.cancel()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: HelmLink.nanoseconds(HelmLink.keepaliveInterval))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.sendKeepalive()
            }
        }
    }

    /// Re-sending the whole subscribe burst is what keeps video flowing; the
    /// plotter treats a gap of more than a few seconds as "client went away".
    private func sendKeepalive() {
        guard phase == .ready, let connection else { return }
        connection.send(content: Helm.subscribeFrames(), completion: .contentProcessed { _ in })
    }

    // MARK: - Read loop

    private func receiveNext(_ gen: Int) {
        guard gen == generation, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Reduce NWError to a String here: only Sendable values may cross onto the actor.
            let reason = error.map { HelmLink.describe($0) }
            Task { await self.received(gen, data: data, isComplete: isComplete, error: reason) }
        }
    }

    private func received(_ gen: Int, data: Data?, isComplete: Bool, error: String?) {
        guard gen == generation, phase == .ready else { return }

        if let data, !data.isEmpty {
            inbound.append(contentsOf: data)
            if inbound.count > Self.maxBufferBytes { inbound.removeAll(keepingCapacity: false) }
            drainFrames()
        }

        if let error {
            connectionDropped(gen, reason: error)
            return
        }
        if isComplete {
            connectionDropped(gen, reason: "the plotter closed the connection")
            return
        }
        receiveNext(gen)
    }

    /// TCP is a byte stream: one read may hold half a frame or six frames.
    /// Consume exactly what `HelmFrame.decode` reports and keep the remainder.
    private func drainFrames() {
        while inbound.count >= 8 {
            // Header is [u16 type][u16 0xBEEF][u32 len], all little-endian, so
            // bytes 2 and 3 must read EF BE.
            guard inbound[2] == 0xEF, inbound[3] == 0xBE else {
                if resynchronise() { continue } else { return }
            }
            let length = Int(inbound[4])
                | Int(inbound[5]) << 8
                | Int(inbound[6]) << 16
                | Int(inbound[7]) << 24
            guard length <= Self.maxPayloadBytes else {
                if resynchronise() { continue } else { return }
            }
            guard inbound.count >= 8 + length,
                  let (frame, consumed) = HelmFrame.decode(inbound) else { return }  // partial frame
            inbound.removeFirst(consumed)
            handle(frame)
        }
    }

    /// Slide forward to the next plausible frame header. Returns false when no
    /// candidate is left, in which case we keep only the trailing bytes that
    /// could still be the front of a header split across two reads.
    private func resynchronise() -> Bool {
        var i = 1
        while i + 4 <= inbound.count {
            if inbound[i + 2] == 0xEF, inbound[i + 3] == 0xBE {
                inbound.removeFirst(i)
                return true
            }
            i += 1
        }
        inbound.removeFirst(max(0, inbound.count - 3))
        return false
    }

    private func handle(_ frame: HelmFrame) {
        guard let message = Helm.parse(frame) else { return }
        switch message {
        case .context(let id):
            ctxId = id
            resumeContextWaiters(throwing: nil)
        case .rtspURL(let url):
            rtspURL = url
            let waiters = rtspWaiters
            rtspWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: url) }
        case .event:
            break
        }
    }

    // MARK: - Waiters

    private func waitUntilReady(timeout: TimeInterval) async throws {
        if phase == .ready { return }
        guard phase != .closed else { throw HelmError.notConnected }

        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: HelmLink.nanoseconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.expireReadyWaiters()
        }
        defer { timer.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters.append(continuation)
        }
    }

    private func waitForContext(timeout: TimeInterval) async throws {
        if ctxId != nil { return }
        guard phase != .closed else { throw HelmError.notConnected }

        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: HelmLink.nanoseconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.expireContextWaiters()
        }
        defer { timer.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            contextWaiters.append(continuation)
        }
    }

    private func expireReadyWaiters() {
        guard !readyWaiters.isEmpty else { return }
        let detail = lastWaitReason ?? "no response from \(host):\(port)"
        resumeReadyWaiters(throwing: HelmError.connectionFailed(detail))
    }

    private func expireContextWaiters() {
        guard !contextWaiters.isEmpty else { return }
        resumeContextWaiters(throwing: HelmError.handshakeTimeout)
    }

    private func expireRTSPWaiters() {
        guard !rtspWaiters.isEmpty else { return }
        let waiters = rtspWaiters
        rtspWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: rtspURL) }
    }

    private func resumeReadyWaiters(throwing error: Error?) {
        guard !readyWaiters.isEmpty else { return }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    private func resumeContextWaiters(throwing error: Error?) {
        guard !contextWaiters.isEmpty else { return }
        let waiters = contextWaiters
        contextWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    // MARK: - Helpers

    private static func endpointHost(_ raw: String) -> NWEndpoint.Host {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bonjour discovery hands back IPv6 literals bracketed, e.g. "[fe80::1]".
        if text.hasPrefix("["), text.hasSuffix("]"), text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        return NWEndpoint.Host(text)
    }

    private static func endpointPort(_ raw: Int) -> NWEndpoint.Port {
        guard raw > 0, raw <= Int(UInt16.max), let port = NWEndpoint.Port(rawValue: UInt16(raw)) else {
            return NWEndpoint.Port(rawValue: 51200)!
        }
        return port
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return String(cString: strerror(code.rawValue)).lowercased()
        default:
            return error.localizedDescription
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(min(max(seconds, 0), 86_400) * 1_000_000_000)
    }
}
