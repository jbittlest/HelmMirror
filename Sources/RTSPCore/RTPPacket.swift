//
//  RTPPacket.swift
//  HelmMirror
//
//  RTP reception, the pure half:
//
//    · `RTPPacket`        — RFC 3550 fixed-header parsing            (pure)
//    · `RTPSeq`           — modulo-2^16 sequence-number arithmetic   (pure)
//    · `RTPReorderBuffer` — jitter/reorder buffer + loss detection   (pure)
//
//  FOUNDATION ONLY. No Network, no CoreMedia, no AVFoundation, no UIKit, no
//  VideoToolbox, no logging. These are the byte-level ground truth pinned by the
//  vectors in Verify/main.swift, and they compile unchanged into the
//  Foundation-only SwiftPM `HelmProtocol` target so `swift run helmverify` keeps
//  working on a Mac with only the Command Line Tools.
//
//  The socket half lives in `Sources/RTSP/RTPUDPTransport.swift`.
//
//  Frozen interface: SPEC §4.3.
//

import Foundation

// MARK: - RTP packet (RFC 3550 §5.1)

/// One parsed RTP packet.
///
/// The CSRC list and the header extension are skipped rather than exposed (this
/// player has no use for either), and trailing padding is removed, so `payload`
/// is exactly the RFC 6184 payload the depacketizer expects.
public struct RTPPacket: Equatable, Sendable {
    public let hasMarker: Bool
    public let payloadType: UInt8
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    /// CSRC list and header extension skipped, trailing padding removed.
    public let payload: Data

    public init(hasMarker: Bool,
                payloadType: UInt8,
                sequenceNumber: UInt16,
                timestamp: UInt32,
                ssrc: UInt32,
                payload: Data) {
        self.hasMarker = hasMarker
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.payload = payload
    }

    /// Header geometry shared by the `[UInt8]` and `Data` entry points.
    /// All offsets are relative to the first byte of the packet.
    private struct Geometry {
        let hasMarker: Bool
        let payloadType: UInt8
        let sequenceNumber: UInt16
        let timestamp: UInt32
        let ssrc: UInt32
        let payloadStart: Int
        let payloadEnd: Int
    }

    /// The whole of RFC 3550 §5.1 that this player cares about.
    ///
    ///   0                   1                   2                   3
    ///   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    ///  |V=2|P|X|  CC   |M|     PT      |       sequence number         |
    ///  |                           timestamp                           |
    ///  |                             SSRC                              |
    ///  |                        CSRC list (CC × 32 bits)               |
    ///  |      defined by profile       |         length (words)        |  ← X
    ///  |                    header extension (length × 32 bits)        |
    ///
    /// Every length is validated against `count` before it is used, so a
    /// truncated or hostile datagram returns nil instead of trapping.
    private static func geometry(count: Int, byte: (Int) -> UInt8) -> Geometry? {
        guard count >= 12 else { return nil }

        let b0 = byte(0)
        guard b0 >> 6 == 2 else { return nil }          // version must be 2
        let hasPadding = b0 & 0x20 != 0
        let hasExtension = b0 & 0x10 != 0
        let csrcCount = Int(b0 & 0x0F)

        let b1 = byte(1)
        let hasMarker = b1 & 0x80 != 0
        let payloadType = b1 & 0x7F

        let sequenceNumber = UInt16(byte(2)) << 8 | UInt16(byte(3))
        let timestamp = UInt32(byte(4)) << 24 | UInt32(byte(5)) << 16
            | UInt32(byte(6)) << 8 | UInt32(byte(7))
        let ssrc = UInt32(byte(8)) << 24 | UInt32(byte(9)) << 16
            | UInt32(byte(10)) << 8 | UInt32(byte(11))

        var headerLength = 12 + 4 * csrcCount
        guard count >= headerLength else { return nil }

        if hasExtension {
            guard count >= headerLength + 4 else { return nil }
            // The extension's own 4-byte header is [profile:16][length:16], where
            // length counts 32-bit words of extension data, NOT including itself.
            let extWords = Int(UInt16(byte(headerLength + 2)) << 8
                | UInt16(byte(headerLength + 3)))
            headerLength += 4 + 4 * extWords
            guard count >= headerLength else { return nil }
        }

        var payloadEnd = count
        if hasPadding {
            // The final byte counts the padding bytes, itself included.
            let padLength = Int(byte(count - 1))
            guard padLength >= 1, padLength <= count - headerLength else { return nil }
            payloadEnd = count - padLength
        }

        return Geometry(hasMarker: hasMarker,
                        payloadType: payloadType,
                        sequenceNumber: sequenceNumber,
                        timestamp: timestamp,
                        ssrc: ssrc,
                        payloadStart: headerLength,
                        payloadEnd: payloadEnd)
    }

    /// nil when the datagram is too short, is not RTP version 2, or declares a
    /// CSRC/extension/padding length that does not fit. An empty payload is legal.
    public static func parse(_ bytes: [UInt8]) -> RTPPacket? {
        guard let g = geometry(count: bytes.count, byte: { bytes[$0] }) else { return nil }
        return RTPPacket(hasMarker: g.hasMarker,
                         payloadType: g.payloadType,
                         sequenceNumber: g.sequenceNumber,
                         timestamp: g.timestamp,
                         ssrc: g.ssrc,
                         payload: Data(bytes[g.payloadStart ..< g.payloadEnd]))
    }

    public static func parse(_ data: Data) -> RTPPacket? {
        // `data` may be a slice whose startIndex is not 0 (Network hands these
        // out), so every access is rebased. `Data(_:)` re-bases the payload to 0.
        let base = data.startIndex
        guard let g = geometry(count: data.count, byte: { data[base + $0] }) else { return nil }
        return RTPPacket(hasMarker: g.hasMarker,
                         payloadType: g.payloadType,
                         sequenceNumber: g.sequenceNumber,
                         timestamp: g.timestamp,
                         ssrc: g.ssrc,
                         payload: Data(data[(base + g.payloadStart) ..< (base + g.payloadEnd)]))
    }
}

// MARK: - Sequence-number arithmetic

/// RTP sequence numbers are 16-bit and wrap. Never compare them with `<`.
public enum RTPSeq {
    /// Signed modulo-2^16 distance `a - b`, in `-32768 ..< 32768`.
    public static func delta(_ a: UInt16, _ b: UInt16) -> Int {
        Int(Int16(bitPattern: a &- b))
    }

    public static func isNewer(_ a: UInt16, than b: UInt16) -> Bool {
        delta(a, b) > 0
    }
}

// MARK: - Reorder buffer

/// A small, bounded jitter buffer.
///
/// UDP delivers RTP out of order and drops packets outright; feeding either
/// straight to the depacketizer produces the green-smear failure mode. This
/// buffer emits packets strictly in sequence order and reports exactly how many
/// sequence numbers it gave up on, which is what drives the corrupt-AU flag and
/// the keyframe gate upstream.
///
/// It is deliberately a value type with no timers: latency is bounded by
/// `capacity` and `maxJump`, not by wall-clock, so it stays deterministic and
/// testable.
public struct RTPReorderBuffer: Sendable {

    public struct Stats: Equatable, Sendable {
        public var received = 0
        public var lost = 0
        public var duplicates = 0
        public var reordered = 0

        public init(received: Int = 0, lost: Int = 0, duplicates: Int = 0, reordered: Int = 0) {
            self.received = received
            self.lost = lost
            self.duplicates = duplicates
            self.reordered = reordered
        }
    }

    public struct Output: Equatable, Sendable {
        /// Ready-to-depacketize packets, ascending in sequence order. May be empty.
        public let packets: [RTPPacket]
        /// Sequence numbers declared lost immediately before `packets`. 0 normally.
        public let lost: Int

        public init(packets: [RTPPacket], lost: Int) {
            self.packets = packets
            self.lost = lost
        }
    }

    /// Max held out-of-order packets before a forced drain.
    public let capacity: Int
    /// Forward gap that forces a drain instead of waiting (stream restart, big burst loss).
    public let maxJump: Int

    public private(set) var stats = Stats()
    /// The next sequence number that can be delivered without a gap.
    public private(set) var expected: UInt16?

    /// Out-of-order packets waiting for their predecessors, keyed by sequence number.
    private var held: [UInt16: RTPPacket] = [:]
    /// Latched on the first packet; a change means the server restarted the stream.
    private var latchedSSRC: UInt32?

    public init(capacity: Int = 32, maxJump: Int = 1024) {
        self.capacity = capacity
        self.maxJump = maxJump
    }

    /// Feed one received packet. The returned packets are in order and contiguous;
    /// `lost` counts the sequence numbers abandoned immediately before them.
    public mutating func push(_ packet: RTPPacket) -> Output {
        stats.received += 1

        // A new SSRC is a new stream: everything held belongs to the old one.
        if let latched = latchedSSRC, latched != packet.ssrc {
            reset()
        }

        let seq = packet.sequenceNumber

        guard let expected else {
            latchedSSRC = packet.ssrc
            self.expected = seq &+ 1
            return Output(packets: [packet], lost: 0)
        }

        let d = RTPSeq.delta(seq, expected)

        if d == 0 {
            var delivered = [packet]
            var next = seq &+ 1
            while let queued = held.removeValue(forKey: next) {
                delivered.append(queued)
                next = next &+ 1
            }
            self.expected = next
            return Output(packets: delivered, lost: 0)
        }

        if d < 0 {
            // Already delivered, or a stale retransmit.
            stats.duplicates += 1
            return Output(packets: [], lost: 0)
        }

        if held[seq] != nil {
            stats.duplicates += 1
            return Output(packets: [], lost: 0)
        }

        held[seq] = packet
        stats.reordered += 1

        if held.count > capacity || d >= maxJump {
            return forceDrain()
        }
        return Output(packets: [], lost: 0)
    }

    /// Deliver everything still held, counting every gap as lost. Call on stop.
    public mutating func flush() -> Output {
        guard let expected, !held.isEmpty else {
            held.removeAll()
            return Output(packets: [], lost: 0)
        }

        // Sort by distance from `expected`, not by raw value, so a wrap does not
        // reverse the order.
        let ordered = held.keys.sorted { RTPSeq.delta($0, expected) < RTPSeq.delta($1, expected) }

        var delivered: [RTPPacket] = []
        var lost = 0
        var cursor = expected
        for seq in ordered {
            let gap = RTPSeq.delta(seq, cursor)
            if gap > 0 { lost += gap }
            if let packet = held[seq] { delivered.append(packet) }
            cursor = seq &+ 1
        }

        held.removeAll()
        stats.lost += lost
        self.expected = cursor
        return Output(packets: delivered, lost: lost)
    }

    /// Forget the stream position and everything held. `stats` is preserved.
    public mutating func reset() {
        held.removeAll()
        expected = nil
        latchedSSRC = nil
    }

    /// Give up waiting: skip forward to the oldest held packet and drain from there.
    private mutating func forceDrain() -> Output {
        guard let expected else { return Output(packets: [], lost: 0) }

        var oldestSeq: UInt16?
        var oldestDelta = Int.max
        for seq in held.keys {
            let d = RTPSeq.delta(seq, expected)
            if d > 0 && d < oldestDelta {
                oldestDelta = d
                oldestSeq = seq
            }
        }

        guard let first = oldestSeq, let packet = held.removeValue(forKey: first) else {
            return Output(packets: [], lost: 0)
        }

        let lost = oldestDelta
        stats.lost += lost

        var delivered = [packet]
        var next = first &+ 1
        while let queued = held.removeValue(forKey: next) {
            delivered.append(queued)
            next = next &+ 1
        }
        self.expected = next
        return Output(packets: delivered, lost: lost)
    }
}
