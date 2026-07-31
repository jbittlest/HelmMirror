//
//  RTPUDPTransport.swift
//  HelmMirror
//
//  The socket half of RTP reception: the client's `RTP/AVP` UDP port pair.
//  Everything byte-level lives in `Sources/RTSPCore/RTPPacket.swift`; this file
//  only moves datagrams and is the only part that needs Network.framework.
//
//  Frozen interface: SPEC §5.2.
//

import Foundation
import Network

/// The client half of an `RTP/AVP` unicast session: an even UDP port for RTP and
/// the next odd port for RTCP, as RFC 3550 §11 requires.
///
/// Set `onRTP` and `onLog` before calling `start()`; both fire on the queue given
/// to `init`, except the one-shot "udp ports" line which is emitted synchronously
/// from `start()` so it lands in the diagnostic log ahead of "tcp connect".
///
/// v1 never transmits: no Receiver Reports, no hole punching. The plotter is on
/// the same LAN with no NAT in between, and the RTSP-level keepalive already
/// holds the session open — which is exactly how `ffplay -rtsp_transport udp`
/// behaves against this stream.
public final class RTPUDPTransport: @unchecked Sendable {

    public struct Ports: Equatable, Sendable {
        public let rtp: UInt16      // always even
        public let rtcp: UInt16     // always rtp + 1

        public init(rtp: UInt16, rtcp: UInt16) {
            self.rtp = rtp
            self.rtcp = rtcp
        }
    }

    /// Ephemeral-ish range that avoids the system's own ephemeral allocations and
    /// leaves room for the odd RTCP partner at the top end.
    private static let portRangeLow: UInt16 = 50000
    private static let portRangeHigh: UInt16 = 59998

    public let ports: Ports

    /// One datagram, on the transport's queue. Set before `start()`.
    public var onRTP: ((Data) -> Void)?
    /// Diagnostics. Set before `start()`.
    public var onLog: ((String) -> Void)?

    private let queue: DispatchQueue
    private let rtpListener: NWListener
    private let rtcpListener: NWListener

    /// Guards `started`, `stopped` and `connections`; `start()`/`stop()` are
    /// documented as callable from any thread, and the accept handler runs on
    /// `queue`, so a lock is simpler (and deadlock-free) than bouncing through it.
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    /// **Retained on purpose.** A UDP `NWListener` vends one `NWConnection` per
    /// remote endpoint; dropping the reference tears the flow down and the RTP
    /// stops dead.
    private var connections: [NWConnection] = []

    /// Binds an even RTP port and rtp+1 for RTCP, retrying `attempts` random even
    /// bases in 50000...59998. Returns nil when every attempt fails to bind, which
    /// is a normal outcome: the caller falls straight through to interleaved TCP.
    public init?(queue: DispatchQueue, attempts: Int = 8) {
        var bound: (Ports, NWListener, NWListener)?

        for _ in 0 ..< max(1, attempts) {
            let base = Self.randomEvenBase()
            // NWListener only reports a bind failure asynchronously, long after
            // init has returned, so probe both ports with a throwaway datagram
            // socket first. That keeps `init?` honest about the port pair.
            guard Self.portIsAvailable(base), Self.portIsAvailable(base + 1) else { continue }
            guard let rtpPort = NWEndpoint.Port(rawValue: base),
                  let rtcpPort = NWEndpoint.Port(rawValue: base + 1) else { continue }
            // A fresh NWParameters per listener: one instance must not be shared.
            guard let rtp = try? NWListener(using: Self.udpParameters(), on: rtpPort),
                  let rtcp = try? NWListener(using: Self.udpParameters(), on: rtcpPort) else { continue }
            bound = (Ports(rtp: base, rtcp: base + 1), rtp, rtcp)
            break
        }

        guard let (ports, rtp, rtcp) = bound else { return nil }
        self.queue = queue
        self.ports = ports
        self.rtpListener = rtp
        self.rtcpListener = rtcp
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        if started || stopped {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        onLog?("udp ports \(ports.rtp)/\(ports.rtcp)")
        arm(rtpListener, label: "rtp", deliversRTP: true)
        arm(rtcpListener, label: "rtcp", deliversRTP: false)
    }

    /// Idempotent. Cancels both listeners and every accepted connection; no
    /// callback fires afterwards.
    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let open = connections
        connections.removeAll()
        lock.unlock()

        for listener in [rtpListener, rtcpListener] {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
        }
        for connection in open {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    // MARK: Listeners

    private func arm(_ listener: NWListener, label: String, deliversRTP: Bool) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.onLog?("udp \(label) listener failed: \(error.localizedDescription)")
            case .waiting(let error):
                self.onLog?("udp \(label) listener waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.adopt(connection, deliversRTP: deliversRTP)
        }
        listener.start(queue: queue)
    }

    private func adopt(_ connection: NWConnection, deliversRTP: Bool) {
        lock.lock()
        if stopped {
            lock.unlock()
            connection.cancel()
            return
        }
        connections.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, deliversRTP: deliversRTP)
    }

    private func receive(on connection: NWConnection, deliversRTP: Bool) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            self.lock.lock()
            let isStopped = self.stopped
            self.lock.unlock()
            if isStopped { return }

            if deliversRTP, let data, !data.isEmpty {
                self.onRTP?(data)
            }
            // For UDP every datagram is a complete message, so `isComplete` is
            // true on each one — only `isComplete` *with no data* means the flow
            // itself is finished. Re-arming on `isComplete` alone would stop the
            // stream after a single packet.
            if error != nil || (isComplete && data == nil) {
                connection.cancel()
                self.forget(connection)
                return
            }
            self.receive(on: connection, deliversRTP: deliversRTP)
        }
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }

    // MARK: Port selection

    private static func udpParameters() -> NWParameters {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        return params
    }

    private static func randomEvenBase() -> UInt16 {
        let slots = (portRangeHigh - portRangeLow) / 2
        return portRangeLow + 2 * UInt16.random(in: 0 ... slots)
    }

    /// Bind a plain datagram socket to `port` on 0.0.0.0 and immediately release
    /// it. Deliberately *without* SO_REUSEADDR, so a port already held by another
    /// process reports EADDRINUSE rather than silently double-binding.
    private static func portIsAvailable(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)     // INADDR_ANY

        return withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
