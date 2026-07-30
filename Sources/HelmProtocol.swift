//
//  HelmProtocol.swift
//  HelmMirror
//
//  FOUNDATION ONLY. No UIKit. No Network. No SwiftUI.
//  Every symbol in this file must compile and unit-test on macOS via `swift test`.
//  This is the frozen, byte-level ground truth for the Garmin Helm wire protocol
//  (reverse-engineered against a Garmin GPSMAP 923xsv; all plaintext, no TLS).
//
//  Owned by the architect. Implementers of the app-layer files depend on the
//  public API here but MUST NOT change the byte layouts below.
//

import Foundation

// MARK: - Shared cross-file model types
// (These cross file boundaries. Every app-layer file uses these exact definitions.
//  They are Foundation-only on purpose so this file never imports Network/UIKit.)

/// One physical Garmin chartplotter discovered on the local network.
/// Foundation-only: carries a resolved host string + ports, never an NWEndpoint,
/// so this model stays testable and importable everywhere.
public struct DiscoveredPlotter: Identifiable, Equatable, Hashable {
    /// Stable identity. Use the Bonjour service instance name (e.g. "GPSMAP 923").
    public let id: String
    /// Human-readable display name.
    public let name: String
    /// Resolved host: a concrete IPv4/IPv6 literal or a ".local" hostname.
    /// nil until `GarminDiscovery.resolve(_:)` fills it in.
    public var host: String?
    /// Helm session TCP port (`_garmin-helm._tcp`). Default 51200.
    public var helmPort: Int
    /// Pairing/identity HTTP port (`_garmin-bl-id._tcp`). Default 80.
    public var pairingPort: Int
    /// Raw TXT record keys merged from advertised services (tag/hasDisplay/version).
    public var txt: [String: String]

    public init(id: String,
                name: String,
                host: String? = nil,
                helmPort: Int = 51200,
                pairingPort: Int = 80,
                txt: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.host = host
        self.helmPort = helmPort
        self.pairingPort = pairingPort
        self.txt = txt
    }

    /// Deterministic RTSP fallback URL (used only if the EVENT URL never arrives).
    public var fallbackRTSPURL: String? {
        guard let host else { return nil }
        return "rtsp://\(host):554/helm_1280x720.h264"
    }
}

/// Session lifecycle, surfaced to the UI. Equatable so SwiftUI can diff it.
public enum ConnectionState: Equatable {
    case idle
    case discovering
    case connecting
    case handshaking
    /// TCP up + handshake sent, but the plotter has not authorized this client.
    /// Show the "approve on the MFD" instructions.
    case needsPairingApproval
    /// Session established; `rtspURL` is authoritative (EVENT) or fallback.
    case streaming(rtspURL: String)
    case disconnected
    case failed(reason: String)
}

/// Inbound session messages of interest, produced by `Helm.parse(_:)`.
public enum HelmInbound: Equatable {
    /// CONTEXT: the touch context id to prefix every TOUCH frame with.
    case context(UInt32)
    /// EVENT subtype 0: authoritative RTSP URL string.
    case rtspURL(String)
    /// Any other EVENT (e.g. subtype 1 = inline H.264 + device name). Kept raw.
    case event(subtype: UInt32, data: Data)
}

/// A single normalized touch point captured from the mirror view.
public struct HelmTouchPoint: Equatable {
    /// Small stable per-finger id (0,1,2,...). See MirrorPlayerView mapping.
    public var trackId: UInt8
    /// Normalized X across the *displayed video content* (0.0 = left, 1.0 = right).
    public var nx: Double
    /// Normalized Y across the *displayed video content* (0.0 = top, 1.0 = bottom).
    public var ny: Double
    /// true for began/moved (press), false for ended/cancelled (release).
    public var down: Bool

    public init(trackId: UInt8, nx: Double, ny: Double, down: Bool) {
        self.trackId = trackId
        self.nx = nx
        self.ny = ny
        self.down = down
    }
}

/// Errors that cross file boundaries.
public enum HelmError: Error, Equatable {
    case http(Int)
    case handshakeTimeout
    case notConnected
    case invalidFrame
    case pairingRejected
    case connectionFailed(String)
}

// MARK: - Byte / endian helpers

/// Little-endian byte accumulator.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}

    public mutating func u8(_ v: UInt8) { bytes.append(v) }

    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
    }

    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }

    /// Unsigned LEB128 (protobuf) varint.
    public mutating func varint(_ value: UInt64) {
        var n = value
        repeat {
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { b |= 0x80 }
            bytes.append(b)
        } while n != 0
    }

    public mutating func raw(_ v: [UInt8]) { bytes.append(contentsOf: v) }
    public mutating func raw(_ v: Data) { bytes.append(contentsOf: v) }

    public var data: Data { Data(bytes) }
}

/// Little-endian cursor reader. Reads past the end return 0 (callers bounds-check first).
public struct ByteReader {
    private let buf: [UInt8]
    public private(set) var offset: Int

    public init(_ buf: [UInt8], offset: Int = 0) { self.buf = buf; self.offset = offset }
    public init(_ data: Data, offset: Int = 0) { self.buf = Array(data); self.offset = offset }

    public var remaining: Int { max(0, buf.count - offset) }

    public mutating func u8() -> UInt8 {
        guard offset < buf.count else { return 0 }
        defer { offset += 1 }
        return buf[offset]
    }

    public mutating func u16() -> UInt16 {
        let a = UInt16(u8()); let b = UInt16(u8())
        return a | (b << 8)
    }

    public mutating func u32() -> UInt32 {
        let a = UInt32(u8()); let b = UInt32(u8())
        let c = UInt32(u8()); let d = UInt32(u8())
        return a | (b << 8) | (c << 16) | (d << 24)
    }
}

// MARK: - Frame codec
// Wire frame: [u16 type LE][u16 0xBEEF LE][u32 length LE][payload of `length` bytes]

public struct HelmFrame: Equatable {
    public static let magic: UInt16 = 0xBEEF

    public let type: UInt16
    public let payload: Data

    public init(type: UInt16, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    /// Encode this frame to wire bytes.
    public func encoded() -> Data {
        var w = ByteWriter()
        w.u16(type)
        w.u16(HelmFrame.magic)
        w.u32(UInt32(payload.count))
        w.raw(payload)
        return w.data
    }

    /// Decode exactly one frame from the front of `buf`.
    /// Returns the frame and the total number of bytes consumed, or nil if `buf`
    /// does not yet hold a complete frame. Does NOT validate the magic (a stream
    /// re-sync policy is a session-layer concern); callers may check `.magic`.
    public static func decode(_ buf: [UInt8]) -> (frame: HelmFrame, consumed: Int)? {
        guard buf.count >= 8 else { return nil }
        var r = ByteReader(buf)
        let type = r.u16()
        _ = r.u16()                       // magic (0xBEEF)
        let len = Int(r.u32())
        guard len >= 0, buf.count >= 8 + len else { return nil }
        let payload = Data(buf[8 ..< 8 + len])
        return (HelmFrame(type: type, payload: payload), 8 + len)
    }

    public static func decode(_ data: Data) -> (frame: HelmFrame, consumed: Int)? {
        decode(Array(data))
    }
}

// MARK: - Message types + builders + inbound parser

public enum Helm {
    // Message type IDs.
    public static let HELLO: UInt16     = 0x083F   // client -> plotter
    public static let TOKEN: UInt16     = 0x0AA9   // client -> plotter
    public static let SUBSCRIBE: UInt16 = 0x1648   // client -> plotter (repeated, one u32 index each)
    public static let ACQUIRE: UInt16   = 0x1644   // client -> plotter (empty payload)
    public static let CONTEXT: UInt16   = 0x1645   // plotter -> client
    public static let EVENT: UInt16     = 0x1649   // plotter -> client
    public static let TOUCH: UInt16     = 0x164C   // client -> plotter

    /// HELLO payload tag (u16 LE 0x9531).
    public static let helloTag: UInt16 = 0x9531

    /// Observed subscription index sequence for the GPSMAP 923xsv.
    /// Each value is sent as its OWN 0x1648 frame with a 4-byte u32 LE payload.
    /// NOTE: 0x00, 0x01, 0x08, 0x0a each appear twice — send all 16, in order,
    /// duplicates included. Treat as an opaque captured constant; re-verify on
    /// other MFD models and leave this hook to swap it.
    public static let subscribeIndices: [UInt32] =
        [0x0b, 0x00, 0x01, 0x06, 0x08, 0x0a, 0x03, 0x04,
         0x05, 0x09, 0x01, 0x08, 0x00, 0x0a, 0x02, 0x0c]

    // ---- Handshake builders (each returns fully-framed wire bytes) ----

    public static func hello() -> Data {
        var w = ByteWriter(); w.u16(helloTag)
        return HelmFrame(type: HELLO, payload: w.data).encoded()
    }

    /// TOKEN carries 8 client-chosen random bytes.
    public static func token(_ eight: [UInt8]) -> Data {
        precondition(eight.count == 8, "session token must be exactly 8 bytes")
        return HelmFrame(type: TOKEN, payload: Data(eight)).encoded()
    }

    /// One SUBSCRIBE frame for a single index (4-byte u32 LE payload).
    public static func subscribeFrame(index: UInt32) -> Data {
        var w = ByteWriter(); w.u32(index)
        return HelmFrame(type: SUBSCRIBE, payload: w.data).encoded()
    }

    /// The full subscription burst: all 16 SUBSCRIBE frames concatenated, in order.
    /// This is both the handshake subscribe step AND the keepalive payload.
    public static func subscribeFrames(_ indices: [UInt32] = subscribeIndices) -> Data {
        var out = Data()
        for idx in indices { out.append(subscribeFrame(index: idx)) }
        return out
    }

    public static func acquire() -> Data {
        HelmFrame(type: ACQUIRE, payload: Data()).encoded()
    }

    /// Fully-framed TOUCH message for one or more fingers.
    public static func touch(ctxId: UInt32, points: [HelmTouchPoint]) -> Data {
        HelmFrame(type: TOUCH, payload: HelmTouch.encode(ctxId: ctxId, points: points)).encoded()
    }

    // ---- Inbound parsing ----

    /// Interpret a decoded frame. Returns nil for frames we don't act on.
    public static func parse(_ f: HelmFrame) -> HelmInbound? {
        switch f.type {
        case CONTEXT:
            // payload = [u32 LE 1][u32 LE ctx_id]; use the SECOND u32.
            guard f.payload.count >= 8 else { return nil }
            var r = ByteReader(f.payload)
            _ = r.u32()
            return .context(r.u32())

        case EVENT:
            // payload = [u32 LE subtype][u32 LE len][data]
            guard f.payload.count >= 8 else { return nil }
            var r = ByteReader(f.payload)
            let subtype = r.u32()
            let len = Int(r.u32())
            let end = min(8 + max(0, len), f.payload.count)
            let data = Data(Array(f.payload)[8 ..< end])
            if subtype == 0 {
                // subtype 0 is the authoritative RTSP URL as UTF-8; trim NUL/whitespace.
                if let s = String(data: data, encoding: .utf8) {
                    let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \r\n"))
                    if !trimmed.isEmpty { return .rtspURL(trimmed) }
                }
                return .event(subtype: 0, data: data)
            }
            return .event(subtype: subtype, data: data)

        default:
            return nil
        }
    }
}

// MARK: - Touch payload encoder (16.16 fixed-point, normalized)

public enum HelmTouch {
    /// Fixed-point ceiling. Normalized 1.0 -> 65536 (= 0x00010000). Clamp is [0, 65536].
    public static let unity: Double = 65536.0

    /// Encode a normalized 0..1 coordinate to 16.16 fixed point.
    /// encoded = clamp(round(v * 65536), 0, 65536).
    ///
    /// Rounds half-to-even to stay bit-identical to the reference encoder
    /// (helm-linux uses Python's `round()`, which is banker's rounding).
    /// Swift's default `.rounded()` rounds half away from zero and would differ
    /// by 1 LSB on exact .5 boundaries.
    public static func fixed16_16(_ v: Double) -> UInt32 {
        let clamped = min(max(v, 0.0), 1.0)
        return UInt32((clamped * unity).rounded(.toNearestOrEven))
    }

    /// TOUCH payload (NOT framed):
    ///   [u32 LE ctx_id][u32 LE count]  then count * 16-byte points, each:
    ///   [u8 track_id][u32 LE x][u32 LE y][u32 LE down][3 bytes 0x00 pad]
    /// down: 1 = press/move, 0 = release.
    ///
    /// This is the clean multi-finger form used for taps and drags. The plotter's
    /// idiosyncratic 40-byte two-finger PINCH template is intentionally NOT produced
    /// here (single/independent points cover normal control); see SPEC "Pinch" note.
    public static func encode(ctxId: UInt32, points: [HelmTouchPoint]) -> Data {
        var w = ByteWriter()
        w.u32(ctxId)
        w.u32(UInt32(points.count))
        for p in points {
            w.u8(p.trackId)
            w.u32(fixed16_16(p.nx))
            w.u32(fixed16_16(p.ny))
            w.u32(p.down ? 1 : 0)
            w.raw([0x00, 0x00, 0x00])
        }
        return w.data
    }
}

// MARK: - Pairing (protobuf MobileDeviceIdentity + <tag> derivation)

public enum Pairing {
    /// Protobuf `CSM.Proto.Common.MobileDeviceIdentity`, hand-encoded:
    ///   field 1 (0x0A) string  device_identifier  (UUID TEXT, 36 chars, not packed bytes)
    ///   field 2 (0x10) uint32  client_generated_token  (LEB128 varint, wire type 0)
    ///   field 3 (0x1A) string  device_name
    public static func identityMessage(deviceId: String,
                                       token: UInt32,
                                       deviceName: String) -> Data {
        var w = ByteWriter()

        // field 1: tag 0x0A, len-delimited UTF-8
        w.u8(0x0A)
        let id = Array(deviceId.utf8)
        w.varint(UInt64(id.count))
        w.raw(id)

        // field 2: tag 0x10, varint uint32
        w.u8(0x10)
        w.varint(UInt64(token))

        // field 3: tag 0x1A, len-delimited UTF-8
        w.u8(0x1A)
        let nm = Array(deviceName.utf8)
        w.varint(UInt64(nm.count))
        w.raw(nm)

        return w.data
    }

    /// <tag> = base64( token[4 bytes LITTLE-ENDIAN] || 0x02 0x01 0x00 0x00 ), '=' stripped.
    /// The SAME token feeds both protobuf field 2 (as a varint) and this tag
    /// (as 4 LE bytes) — the plotter cross-checks them.
    public static func tag(for token: UInt32) -> String {
        var b = withUnsafeBytes(of: token.littleEndian) { Array($0) }   // 4 bytes LE
        b += [0x02, 0x01, 0x00, 0x00]
        return Data(b).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// A random 32-bit token whose `tag` is URL-path-safe (no '+' or '/'),
    /// so it can be placed in the PUT path byte-for-byte without percent-encoding.
    public static func makePathSafeToken() -> UInt32 {
        while true {
            let t = UInt32.random(in: UInt32.min ... UInt32.max)
            let s = tag(for: t)
            if !s.contains("+") && !s.contains("/") { return t }
        }
    }
}
