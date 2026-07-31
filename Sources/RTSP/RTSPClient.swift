//
//  RTSPClient.swift
//  HelmMirror
//
//  The RTSP 1.0 conversation with the plotter over one Network.framework TCP
//  connection: OPTIONS → DESCRIBE → SETUP → PLAY, keepalive, TEARDOWN.
//
//  Three jobs, and nothing else:
//    1. Talk  — build requests with `RTSPRequestBuilder`, track CSeq and the
//       `Session:` id, drive the state machine off the matching responses.
//    2. Demux — feed every received byte to `RTSPWireDecoder`, which yields
//       responses, server-initiated requests, and `$`-interleaved RTP frames
//       from the same octet stream (RFC 2326 §10.12).
//    3. Report — every request and response line is handed to the delegate as a
//       pre-formatted string. `RTSPVideoSession` forwards those to
//       `MirrorDiagnostics.shared`, which is what puts the handshake on screen.
//       That on-screen visibility is a deliverable (SPEC §11), not a nicety, so
//       the log calls here are load-bearing: do not "clean them up".
//
//  All byte-level parsing lives in `Sources/RTSPCore/` (Foundation-only, vector
//  tested by `swift run helmverify`). This file is pure transport + lifecycle and
//  imports nothing but Foundation and Network — no UIKit, no VideoToolbox.
//
//  Threading: the caller's serial queue owns every mutable property. NWConnection
//  delivers its state, send and receive callbacks on that same queue, so no lock
//  is needed for state; the single exception is the `stopped` flag, which `stop()`
//  sets synchronously from any thread so that no delegate call can escape after it.
//

import Foundation
import Network

// MARK: - Public types

/// How RTP reaches us: its own UDP socket pair, or `$`-interleaved on this very
/// TCP connection.
public enum RTSPTransportMode: Equatable {
    case udp
    case tcpInterleaved
}

/// Everything the media path needs once PLAY has been answered.
public struct RTSPMediaSetup {
    public let track: H264TrackDescription
    public let trackURI: String
    public let aggregateURI: String            // the URI PLAY/TEARDOWN are sent to
    public let mode: RTSPTransportMode
    public let serverRTPPort: UInt16?          // UDP only
    public let serverRTCPPort: UInt16?         // UDP only
    public let rtpChannel: UInt8               // interleaved only; 0 by convention
    public let rtcpChannel: UInt8              // interleaved only; 1 by convention
    public let sessionId: String
    public let sessionTimeout: TimeInterval    // seconds; 60 when the server omits it

    public init(track: H264TrackDescription,
                trackURI: String,
                aggregateURI: String,
                mode: RTSPTransportMode,
                serverRTPPort: UInt16?,
                serverRTCPPort: UInt16?,
                rtpChannel: UInt8,
                rtcpChannel: UInt8,
                sessionId: String,
                sessionTimeout: TimeInterval) {
        self.track = track
        self.trackURI = trackURI
        self.aggregateURI = aggregateURI
        self.mode = mode
        self.serverRTPPort = serverRTPPort
        self.serverRTCPPort = serverRTCPPort
        self.rtpChannel = rtpChannel
        self.rtcpChannel = rtcpChannel
        self.sessionId = sessionId
        self.sessionTimeout = sessionTimeout
    }
}

public enum RTSPClientError: Error, Equatable {
    case badURL(String)
    case connectionFailed(String)
    case timeout(step: String)
    case status(method: String, code: Int, reason: String)
    case unauthorized(challenge: String?)     // 401; auth is out of scope
    case transportRejected(code: Int)         // 461 / 457 — caller should try the other transport
    case noH264Track
    case malformedResponse(String)
    case cancelled
}

extension RTSPClientError: CustomStringConvertible {
    /// One short line, sized for the on-screen log (`err: <description>`, SPEC §11).
    public var description: String {
        switch self {
        case .badURL(let url):
            return "bad URL \(url)"
        case .connectionFailed(let reason):
            return "connection failed: \(reason)"
        case .timeout(let step):
            return "timeout during \(step)"
        case .status(let method, let code, let reason):
            return "\(method) -> \(code) \(reason)"
        case .unauthorized(let challenge):
            return challenge.map { "401 unauthorized: \($0)" } ?? "401 unauthorized"
        case .transportRejected(let code):
            return "\(code) transport rejected"
        case .noH264Track:
            return "no H.264 track in the SDP"
        case .malformedResponse(let detail):
            return "malformed response: \(detail)"
        case .cancelled:
            return "cancelled"
        }
    }
}

public protocol RTSPClientDelegate: AnyObject {
    /// Every line already formatted for MirrorDiagnostics. Called on the client queue.
    func rtspClient(_ client: RTSPClient, didLog line: String)
    /// PLAY returned 200. RTP may start arriving before or after this call.
    func rtspClient(_ client: RTSPClient, didPlay setup: RTSPMediaSetup)
    /// One `$` frame. Only fires in .tcpInterleaved mode (but handle it in both).
    func rtspClient(_ client: RTSPClient, didReceiveInterleaved channel: UInt8, payload: Data)
    func rtspClient(_ client: RTSPClient, didFailWith error: RTSPClientError)
    /// The RTSP connection closed after a successful PLAY.
    func rtspClientDidEnd(_ client: RTSPClient)
}

// MARK: - Client

/// One RTSP session against one URL with one transport. Not reusable: a failed
/// attempt is discarded and a fresh client is built for the retry (that is how
/// `RTSPVideoSession` implements its UDP → interleaved-TCP fallback).
///
/// `@unchecked Sendable`: every stored property is confined to `queue`, and the
/// only cross-thread member is the lock-guarded `stopped` flag.
public final class RTSPClient: @unchecked Sendable {

    // MARK: Tunables (SPEC §5.1; the outer MirrorAttempt ladder budgets 8 s per attempt)

    /// Time allowed for the TCP connection to reach `.ready`.
    private static let connectTimeout: TimeInterval = 6.0
    /// Time allowed for a response to any handshake request.
    private static let requestTimeout: TimeInterval = 5.0
    /// Keepalives are not urgent; give them a much longer leash than the handshake.
    private static let keepaliveTimeout: TimeInterval = 10.0
    /// How long `stop()` lets TEARDOWN sit on the socket before cancelling it.
    private static let teardownGrace: TimeInterval = 0.2
    /// Used when the server sends `Session:` with no `timeout=` parameter.
    private static let defaultSessionTimeout: TimeInterval = 60
    /// Upper bound on a single NWConnection receive.
    private static let maxReceive = 64 * 1024
    /// Only compact the receive buffer once this many bytes have been consumed —
    /// interleaved TCP pushes megabytes per second and a per-item `removeFirst`
    /// would turn the drain loop quadratic.
    private static let compactThreshold = 65536
    /// MirrorDiagnostics is read off a phone screen on a moving boat (SPEC §11).
    private static let maxLogLine = 110

    // MARK: Immutable config

    private let urlString: String
    private let requestedMode: RTSPTransportMode
    private let clientRTPPort: UInt16?
    private let queue: DispatchQueue

    public weak var delegate: RTSPClientDelegate?

    // MARK: State (queue-confined)

    /// Where the handshake has got to. `pending` says which request is in flight.
    private enum Phase {
        case idle, connecting, handshaking, playing, finished
    }

    /// Which response we are waiting for, so the CSeq match can advance the machine.
    private enum Step {
        case options, describe, setup, play, keepalive

        /// The `step:` string carried by `.timeout`.
        var timeoutName: String {
            switch self {
            case .options:   return "OPTIONS"
            case .describe:  return "DESCRIBE"
            case .setup:     return "SETUP"
            case .play:      return "PLAY"
            case .keepalive: return "keepalive"
            }
        }
    }

    private struct Pending {
        let cseq: Int
        let method: String
        let step: Step
    }

    private var phase: Phase = .idle
    private var connection: NWConnection?
    private var host = ""
    private var port: UInt16 = 554

    /// Rolling receive buffer plus a read index. Never sliced per item (see
    /// `compactThreshold`).
    private var rx = [UInt8]()
    private var readIndex = 0

    private var nextCSeq = 1
    private var pending: Pending?

    /// Bumped on every arm/cancel; a fired timer whose generation is stale is ignored.
    /// Safe because arming, cancelling and firing all happen on `queue`.
    private var timeoutGeneration = 0
    private var keepaliveGeneration = 0

    private var sessionId: String?
    private var sessionTimeout: TimeInterval = RTSPClient.defaultSessionTimeout
    private var supportsGetParameter = false

    /// Negotiated from the SETUP response; may differ from `requestedMode` if the
    /// server answers a UDP request with an interleaved transport.
    private var negotiatedMode: RTSPTransportMode
    private var rtpChannel: UInt8 = 0
    private var rtcpChannel: UInt8 = 1
    private var serverRTPPort: UInt16?
    private var serverRTCPPort: UInt16?

    private var track: H264TrackDescription?
    private var trackURI = ""
    /// PLAY / GET_PARAMETER / TEARDOWN target. Content-Base of the DESCRIBE response,
    /// with the SDP's session-level `a=control` applied (which is `*` — i.e. a no-op —
    /// on this plotter). SETUP alone goes to `trackURI`.
    private var aggregateURI = ""

    private var hasPlayed = false
    private var loggedKeepalive = false
    private var loggedWaiting = false

    /// Set synchronously by `stop()` from any thread; checked before every delegate
    /// call so nothing escapes once the caller has let go.
    private let stopLock = NSLock()
    private var stopped = false

    // MARK: Init

    public init(url: String,
                mode: RTSPTransportMode,
                clientRTPPort: UInt16?,
                queue: DispatchQueue) {
        self.urlString = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestedMode = mode
        self.negotiatedMode = mode
        self.clientRTPPort = clientRTPPort
        self.queue = queue
    }

    // MARK: Lifecycle

    /// Connect and run the handshake. Subsequent calls are ignored.
    public func start() {
        queue.async { [weak self] in self?.performStart() }
    }

    /// Best-effort TEARDOWN then cancel. Idempotent, safe from any thread.
    public func stop() {
        stopLock.lock()
        let alreadyStopped = stopped
        stopped = true
        stopLock.unlock()
        guard !alreadyStopped else { return }
        queue.async { [weak self] in self?.performStop() }
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func performStart() {
        guard phase == .idle, !isStopped else { return }

        guard let (h, p) = Self.hostAndPort(from: urlString) else {
            fail(.badURL(urlString))
            return
        }
        host = h
        port = p

        if requestedMode == .udp, clientRTPPort == nil {
            fail(.connectionFailed("UDP transport requested without a client RTP port"))
            return
        }

        phase = .connecting
        log("tcp connect \(host):\(port)")

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                       // interactive: never coalesce our requests
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false         // the MFD is a Wi-Fi AP, not an AWDL peer

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fail(.badURL(urlString))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)             // delivered on `queue`
        }
        conn.start(queue: queue)
        armTimeout(Self.connectTimeout, step: "connect")
    }

    private func performStop() {
        cancelTimeout()
        cancelKeepalive()
        pending = nil

        // A TEARDOWN is only meaningful once the server has given us a session id.
        if let conn = connection, let sid = sessionId, phase == .handshaking || phase == .playing {
            let request = RTSPRequestBuilder.teardown(uri: aggregateURI, cseq: takeCSeq(), session: sid)
            NSLog("[HelmMirror] %@", request.wireText)   // no delegate calls after stop()
            conn.send(content: request.serialized(), completion: .contentProcessed { _ in })
        }
        phase = .finished

        // Let TEARDOWN reach the wire, then drop the socket regardless of the answer.
        queue.asyncAfter(deadline: .now() + Self.teardownGrace) { [weak self] in
            self?.closeConnection()
        }
    }

    private func closeConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        rx.removeAll(keepingCapacity: false)
        readIndex = 0
    }

    // MARK: Connection state

    private func handleState(_ state: NWConnection.State) {
        guard !isStopped, phase != .finished else { return }
        switch state {
        case .ready:
            guard phase == .connecting else { return }
            cancelTimeout()
            phase = .handshaking
            armReceive()                    // be listening before we speak
            sendOptions()
        case .waiting(let error):
            // Recoverable (e.g. Wi-Fi still associating); the connect timeout backstops it.
            if !loggedWaiting {
                loggedWaiting = true
                log("tcp waiting: \(error)")
            }
        case .failed(let error):
            fail(.connectionFailed("\(error)"))
        case .cancelled:
            // Only reachable when something other than us cancelled the connection.
            closed()
        default:
            break
        }
    }

    /// The peer closed the connection, or the socket died under us.
    private func closed() {
        guard !isStopped, phase != .finished else { return }
        if hasPlayed {
            phase = .finished
            cancelTimeout()
            cancelKeepalive()
            closeConnection()
            guard !isStopped else { return }
            delegate?.rtspClientDidEnd(self)
        } else {
            fail(.connectionFailed("connection closed before PLAY"))
        }
    }

    // MARK: Receive + demux

    private func armReceive() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReceive) { [weak self] data, _, isComplete, error in
            // NWConnection delivers this on `queue`, so state access below is serial.
            self?.onReceive(data: data, isComplete: isComplete, error: error)
        }
    }

    private func onReceive(data: Data?, isComplete: Bool, error: NWError?) {
        guard !isStopped, phase != .finished else { return }

        if let data, !data.isEmpty {
            rx.append(contentsOf: data)
            guard drain() else { return }         // drain() already failed or stopped us
        }
        if let error {
            fail(.connectionFailed("receive: \(error)"))
            return
        }
        if isComplete {
            closed()
            return
        }
        // Exactly one read is ever outstanding, so bytes — and therefore items — are
        // processed strictly in order.
        armReceive()
    }

    /// Pull every complete item out of the buffer. Returns false when the client
    /// stopped or failed part-way through and the caller must not continue.
    private func drain() -> Bool {
        while true {
            let decoded: (item: RTSPStreamItem, consumed: Int)?
            do {
                decoded = try RTSPWireDecoder.decode(rx, from: readIndex)
            } catch {
                fail(.malformedResponse("\(error)"))
                return false
            }
            guard let (item, consumed) = decoded else { break }
            readIndex += consumed
            handle(item)
            if isStopped || phase == .finished { return false }
        }
        compactBuffer()
        return true
    }

    private func compactBuffer() {
        if readIndex == rx.count {
            // Fully drained — the common case between frames. Reuse the storage.
            rx.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > Self.compactThreshold {
            rx.removeFirst(readIndex)
            readIndex = 0
        }
    }

    private func handle(_ item: RTSPStreamItem) {
        switch item {
        case .interleaved(let frame):
            guard !isStopped else { return }
            delegate?.rtspClient(self, didReceiveInterleaved: frame.channel, payload: frame.payload)
        case .request(let request):
            answer(serverRequest: request)
        case .response(let response):
            handle(response: response)
        }
    }

    /// Some servers poll the client with OPTIONS or push ANNOUNCE. We do not act on
    /// any of it, but an unanswered request can make a server drop the session, so
    /// always reply 200 and move on.
    private func answer(serverRequest: RTSPServerRequest) {
        var text = "RTSP/1.0 200 OK\r\n"
        if let cseq = serverRequest.cseq { text += "CSeq: \(cseq)\r\n" }
        text += "\r\n"
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
        let cseqText = serverRequest.cseq.map { String($0) } ?? "-"
        log("< \(serverRequest.method) from server (CSeq \(cseqText)) -> 200")
    }

    // MARK: Response routing

    private func handle(response: RTSPResponse) {
        NSLog("[HelmMirror] %@", response.headText)

        guard let pending else {
            log("< \(response.statusLine) (unsolicited, ignored)")
            return
        }
        // A missing CSeq is tolerated: there is only ever one request in flight, so an
        // otherwise well-formed response can only belong to it. A *mismatched* CSeq is
        // a stale answer and is dropped without disturbing the state machine.
        if let cseq = response.cseq, cseq != pending.cseq {
            log("< \(response.statusLine) (CSeq \(cseq) unmatched, awaiting \(pending.method) \(pending.cseq))")
            return
        }

        self.pending = nil
        cancelTimeout()

        switch pending.step {
        case .options:   handleOptions(response)
        case .describe:  handleDescribe(response)
        case .setup:     handleSetup(response)
        case .play:      handlePlay(response)
        case .keepalive: handleKeepalive(response)
        }
    }

    // MARK: OPTIONS

    private func sendOptions() {
        let request = RTSPRequestBuilder.options(uri: urlString, cseq: takeCSeq(), session: sessionId)
        send(request, step: .options, timeout: Self.requestTimeout)
    }

    private func handleOptions(_ response: RTSPResponse) {
        let publicHeader = response.header("public")
        // GET_PARAMETER is the polite keepalive; OPTIONS is the fallback (SPEC §5.1).
        supportsGetParameter = (publicHeader ?? "").uppercased().contains("GET_PARAMETER")
        log("< \(response.statusLine)" + (publicHeader.map { "  [Public: \($0)]" } ?? ""))

        // A server that dislikes OPTIONS is still worth a DESCRIBE — this is not fatal.
        if !response.isSuccess {
            log("options \(response.statusCode) ignored, continuing to DESCRIBE")
        }
        sendDescribe()
    }

    // MARK: DESCRIBE

    private func sendDescribe() {
        let request = RTSPRequestBuilder.describe(uri: urlString, cseq: takeCSeq())
        send(request, step: .describe, timeout: Self.requestTimeout)
    }

    private func handleDescribe(_ response: RTSPResponse) {
        if response.statusCode == 401 {
            // Authentication is out of scope (SPEC §1): surface the challenge verbatim
            // so the next person knows exactly what the plotter asked for.
            let challenge = response.header("www-authenticate")
            log("< \(response.statusLine)  WWW-Authenticate: \(challenge ?? "(absent)")")
            fail(.unauthorized(challenge: challenge))
            return
        }
        var line = "< \(response.statusLine)  Content-Length \(response.contentLength)"
        if let base = response.header("content-base") { line += "  base=\(base)" }
        log(line)

        guard response.isSuccess else {
            fail(.status(method: "DESCRIBE", code: response.statusCode, reason: response.reasonPhrase))
            return
        }

        NSLog("[HelmMirror] SDP\n%@", String(decoding: response.body, as: UTF8.self))
        let sdp = SessionDescription.parse(response.body)
        guard let h264 = SDPH264.h264Track(in: sdp) else {
            fail(.noH264Track)
            return
        }
        track = h264

        // Two-step control resolution (SPEC §4.2). `sessionControl` is `*` on this
        // plotter, so the aggregate URI is simply Content-Base.
        let base = RTSPURL.effectiveBase(requestURI: urlString, response: response)
        aggregateURI = RTSPURL.resolve(control: sdp.sessionControl, base: base)
        trackURI = RTSPURL.resolve(control: h264.control, base: aggregateURI)

        let spsBytes = h264.sps.reduce(0) { $0 + $1.count }
        let ppsBytes = h264.pps.reduce(0) { $0 + $1.count }
        log("sdp: video pt=\(h264.payloadType) H264/\(h264.clockRate) pmode=\(h264.packetizationMode)"
            + " sps=\(spsBytes)B pps=\(ppsBytes)B control=\(h264.control ?? "-")")

        sendSetup()
    }

    // MARK: SETUP

    private func sendSetup() {
        let cseq = takeCSeq()
        let request: RTSPRequest
        let transport: String
        switch requestedMode {
        case .udp:
            let rtpPort = clientRTPPort ?? 0
            request = RTSPRequestBuilder.setupUDP(uri: trackURI, cseq: cseq, clientRTPPort: rtpPort)
            transport = "RTP/AVP;unicast;client_port=\(rtpPort)-\(rtpPort &+ 1)"
        case .tcpInterleaved:
            request = RTSPRequestBuilder.setupTCP(uri: trackURI, cseq: cseq, rtpChannel: 0, rtcpChannel: 1)
            transport = "RTP/AVP/TCP;unicast;interleaved=0-1"
        }
        send(request, step: .setup, timeout: Self.requestTimeout, logSuffix: "Transport: \(transport)")
    }

    private func handleSetup(_ response: RTSPResponse) {
        // 461 Unsupported transport / 457 Invalid range are the server's way of saying
        // "not this transport" — a normal fallback outcome, not a broken stream.
        if response.statusCode == 461 || response.statusCode == 457 {
            log("< \(response.statusLine)")
            fail(.transportRejected(code: response.statusCode))
            return
        }
        guard response.isSuccess else {
            log("< \(response.statusLine)")
            fail(.status(method: "SETUP", code: response.statusCode, reason: response.reasonPhrase))
            return
        }
        guard let sid = response.sessionId else {
            log("< \(response.statusLine)  (no Session header)")
            fail(.malformedResponse("SETUP without Session"))
            return
        }

        sessionId = sid
        sessionTimeout = response.sessionTimeout.map { TimeInterval($0) } ?? Self.defaultSessionTimeout

        var extras: [String] = []
        if let raw = response.header("transport") {
            let transport = RTSPTransportHeader.parse(raw)
            if transport.isTCPInterleaved {
                // Believe the server over our own request: if it answered a UDP SETUP
                // with an interleaved transport, RTP will arrive on this socket.
                negotiatedMode = .tcpInterleaved
                rtpChannel = transport.rtpChannel ?? 0
                rtcpChannel = transport.rtcpChannel ?? 1
                extras.append("interleaved=\(rtpChannel)-\(rtcpChannel)")
                if requestedMode == .udp {
                    log("server chose interleaved TCP for a UDP SETUP")
                }
            } else {
                negotiatedMode = .udp
                serverRTPPort = transport.serverRTPPort
                serverRTCPPort = transport.serverRTCPPort
                if let rtp = transport.serverRTPPort {
                    extras.append("server_port=\(rtp)-\(transport.serverRTCPPort ?? rtp &+ 1)")
                }
            }
        }
        extras.append("session=\(sid)")
        if let timeout = response.sessionTimeout { extras.append("timeout=\(timeout)") }
        log("< \(response.statusLine)  " + extras.joined(separator: " "))

        sendPlay()
    }

    // MARK: PLAY

    private func sendPlay() {
        guard let sid = sessionId else {
            fail(.malformedResponse("PLAY without Session"))
            return
        }
        let request = RTSPRequestBuilder.play(uri: aggregateURI, cseq: takeCSeq(), session: sid)
        send(request, step: .play, timeout: Self.requestTimeout)
    }

    private func handlePlay(_ response: RTSPResponse) {
        log("< \(response.statusLine)")
        guard response.isSuccess else {
            fail(.status(method: "PLAY", code: response.statusCode, reason: response.reasonPhrase))
            return
        }
        guard let sid = sessionId, let track else {
            fail(.malformedResponse("PLAY completed without a session or track"))
            return
        }

        phase = .playing
        hasPlayed = true

        let setup = RTSPMediaSetup(track: track,
                                   trackURI: trackURI,
                                   aggregateURI: aggregateURI,
                                   mode: negotiatedMode,
                                   serverRTPPort: serverRTPPort,
                                   serverRTCPPort: serverRTCPPort,
                                   rtpChannel: rtpChannel,
                                   rtcpChannel: rtcpChannel,
                                   sessionId: sid,
                                   sessionTimeout: sessionTimeout)

        scheduleKeepalive()
        guard !isStopped else { return }
        delegate?.rtspClient(self, didPlay: setup)
    }

    // MARK: Keepalive

    /// The plotter drops an idle session at `timeout`; refresh at half that, clamped
    /// so a silly advertised timeout cannot produce a flood or a useless crawl.
    private func scheduleKeepalive() {
        let interval = min(max(sessionTimeout / 2, 5), 25)
        keepaliveGeneration &+= 1
        let generation = keepaliveGeneration
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, generation == self.keepaliveGeneration else { return }
            self.sendKeepalive()
        }
    }

    private func cancelKeepalive() {
        keepaliveGeneration &+= 1
    }

    private func sendKeepalive() {
        guard !isStopped, phase == .playing, let sid = sessionId else { return }
        guard pending == nil else {
            // A keepalive is still outstanding; its own timeout owns the outcome.
            scheduleKeepalive()
            return
        }
        let cseq = takeCSeq()
        let request = supportsGetParameter
            ? RTSPRequestBuilder.getParameter(uri: aggregateURI, cseq: cseq, session: sid)
            : RTSPRequestBuilder.options(uri: aggregateURI, cseq: cseq, session: sid)

        // Only the first keepalive is logged: one line every 25 s would push the whole
        // handshake out of MirrorDiagnostics' 40-line ring, which is the one thing the
        // log exists to show. Anomalies below are always logged.
        let quiet = loggedKeepalive
        loggedKeepalive = true
        send(request, step: .keepalive, timeout: Self.keepaliveTimeout,
             logSuffix: quiet ? nil : "keepalive", quiet: quiet)
    }

    private func handleKeepalive(_ response: RTSPResponse) {
        if !response.isSuccess {
            // Non-fatal by contract: the stream usually keeps flowing regardless.
            log("< \(response.statusLine) (keepalive)")
        }
        scheduleKeepalive()
    }

    // MARK: Sending

    private func takeCSeq() -> Int {
        let cseq = nextCSeq
        nextCSeq += 1
        return cseq
    }

    private func send(_ request: RTSPRequest,
                      step: Step,
                      timeout: TimeInterval,
                      logSuffix: String? = nil,
                      quiet: Bool = false) {
        guard let conn = connection, !isStopped, phase != .finished else { return }

        pending = Pending(cseq: request.cseq, method: request.method, step: step)

        // The full request text goes to NSLog only (SPEC §11); the on-screen ring gets
        // the one-line summary.
        NSLog("[HelmMirror] %@", request.wireText)
        if !quiet {
            var line = "> \(request.method) \(request.uri) (CSeq \(request.cseq))"
            if let logSuffix { line += " " + logSuffix }
            log(line)
        }

        // Capture only the method name: the completion runs on `queue`, and a plain
        // String keeps the closure Sendable under strict concurrency checking.
        let method = request.method
        conn.send(content: request.serialized(), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.fail(.connectionFailed("send \(method): \(error)"))
        })

        armTimeout(timeout, step: step.timeoutName)
    }

    // MARK: Timers

    private func armTimeout(_ seconds: TimeInterval, step: String) {
        timeoutGeneration &+= 1
        let generation = timeoutGeneration
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, generation == self.timeoutGeneration else { return }
            guard !self.isStopped, self.phase != .finished else { return }
            self.fail(.timeout(step: step))
        }
    }

    private func cancelTimeout() {
        timeoutGeneration &+= 1
    }

    // MARK: Delegate plumbing

    private func log(_ line: String) {
        guard !isStopped else { return }
        delegate?.rtspClient(self, didLog: Self.clip(line))
    }

    private func fail(_ error: RTSPClientError) {
        guard !isStopped, phase != .finished else { return }
        phase = .finished
        cancelTimeout()
        cancelKeepalive()
        pending = nil
        closeConnection()
        // Re-check: `stop()` may have landed from another thread while we unwound.
        guard !isStopped else { return }
        delegate?.rtspClient(self, didFailWith: error)
    }

    // MARK: Helpers

    /// `rtsp://172.16.6.155:554/helm_1280x720.h264` -> ("172.16.6.155", 554).
    /// Port defaults to 554. IPv6 literals arrive bracketed; NWEndpoint.Host wants them bare.
    private static func hostAndPort(from url: String) -> (String, UInt16)? {
        guard let components = URLComponents(string: url), var host = components.host, !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let port = components.port.flatMap { UInt16(exactly: $0) } ?? 554
        return (host, port)
    }

    /// No log line may exceed ~110 characters (SPEC §11).
    private static func clip(_ line: String, limit: Int = RTSPClient.maxLogLine) -> String {
        line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }
}
