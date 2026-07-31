//
//  main.swift  —  HelmMirror wire-protocol verifier
//
//  A Foundation-only test harness that checks every byte vector in the frozen
//  SPEC. Deliberately does NOT use XCTest, so it runs on a Mac that has only
//  the Xcode Command Line Tools installed (XCTest ships with full Xcode).
//
//      swift run helmverify
//
//  Exits 0 if all vectors pass, 1 otherwise.
//

import Foundation
import HelmProtocol

// MARK: - Tiny assertion harness

var passed = 0
var failed = 0
var currentSection = ""

func section(_ name: String) {
    currentSection = name
    print("\n\(name)")
}

func check(_ label: String, _ actual: String, _ expected: String) {
    if actual == expected {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ \(label)")
        print("      expected: \(expected)")
        print("      actual:   \(actual)")
    }
}

func check(_ label: String, _ actual: Int, _ expected: Int) {
    check(label, String(actual), String(expected))
}

func check(_ label: String, _ actual: UInt32, _ expected: UInt32) {
    check(label, String(actual), String(expected))
}

func expectTrue(_ label: String, _ cond: Bool) {
    check(label, cond ? "true" : "false", "true")
}

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func hex<S: Sequence>(_ a: S) -> String where S.Element == UInt8 {
    a.map { String(format: "%02x", $0) }.joined()
}

/// "6742e01e" -> Data. Whitespace is ignored so vectors can be written readably.
func unhex(_ s: String) -> Data {
    var out = Data()
    var high: UInt8?
    for ch in s where !ch.isWhitespace {
        guard let nibble = ch.hexDigitValue.map({ UInt8($0) }) else { continue }
        if let h = high {
            out.append(h << 4 | nibble)
            high = nil
        } else {
            high = nibble
        }
    }
    return out
}

func bytes(_ s: String) -> [UInt8] { [UInt8](unhex(s)) }

/// CR and LF made visible, so a failed wire-format comparison is readable.
func escaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\r", with: "\\r")
     .replacingOccurrences(of: "\n", with: "\\n")
}

func checkWire(_ label: String, _ actual: Data, _ expected: String) {
    check(label, escaped(String(decoding: actual, as: UTF8.self)), escaped(expected))
}

print("HelmMirror — wire protocol verification")
print("Foundation-only; no Xcode, no Simulator, no VLC required.")

// MARK: - Frame envelope (SPEC §4.1)

section("Frame envelope")

do {
    let payload = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    let bytes = Array(HelmFrame(type: Helm.TOUCH, payload: payload).encoded())
    check("magic constant is 0xBEEF", String(HelmFrame.magic), String(0xBEEF))
    check("type 0x164C little-endian", hex(bytes[0..<2]), "4c16")
    check("magic 0xBEEF little-endian", hex(bytes[2..<4]), "efbe")
    check("length 6 little-endian", hex(bytes[4..<8]), "06000000")
    check("total frame = 8 + payload", bytes.count, 8 + payload.count)
}

do {
    let bytes = Array(HelmFrame(type: Helm.HELLO, payload: Data([0x31, 0x95])).encoded())
    if let (frame, consumed) = HelmFrame.decode(bytes) {
        check("decode recovers type", String(frame.type), String(Helm.HELLO))
        check("decode recovers payload", hex(frame.payload), "3195")
        check("decode reports bytes consumed", consumed, bytes.count)
    } else {
        failed += 1
        print("  ✗ decode returned nil for a complete frame")
    }
}

do {
    // Header claims a 4-byte payload but only 2 payload bytes are present.
    let partial: [UInt8] = [0x48, 0x16, 0xef, 0xbe, 0x04, 0x00, 0x00, 0x00, 0x0b, 0x00]
    expectTrue("incomplete body -> nil", HelmFrame.decode(partial) == nil)
    expectTrue("short header -> nil", HelmFrame.decode([0x48, 0x16, 0xef]) == nil)
}

do {
    // Reassembly contract: consume exactly one frame and report its length.
    var stream = Array(Helm.acquire())
    stream.append(contentsOf: Array(Helm.subscribeFrame(index: 0x00)))
    if let (first, consumed) = HelmFrame.decode(stream) {
        check("stream: first frame is ACQUIRE", String(first.type), String(Helm.ACQUIRE))
        check("stream: consumed exactly 8 bytes", consumed, 8)
        let rest = Array(stream[consumed...])
        if let (second, consumed2) = HelmFrame.decode(rest) {
            check("stream: second frame is SUBSCRIBE", String(second.type), String(Helm.SUBSCRIBE))
            check("stream: second consumed all", consumed2, rest.count)
        } else {
            failed += 1; print("  ✗ decode of remainder returned nil")
        }
    } else {
        failed += 1; print("  ✗ decode returned nil")
    }
}

// MARK: - Handshake vectors (SPEC §4.3)

section("Handshake frames")

check("HELLO frame", hex(Helm.hello()), "3f08efbe020000003195")
check("TOKEN frame",
      hex(Helm.token([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04])),
      "a90aefbe08000000deadbeef01020304")
check("ACQUIRE frame (empty payload)", hex(Helm.acquire()), "4416efbe00000000")
check("SUBSCRIBE index 0x0b", hex(Helm.subscribeFrame(index: 0x0b)), "4816efbe040000000b000000")
check("SUBSCRIBE index 0x00", hex(Helm.subscribeFrame(index: 0x00)), "4816efbe0400000000000000")

do {
    let burst = Helm.subscribeFrames()
    check("subscribe index count", Helm.subscribeIndices.count, 16)
    check("burst is 16 frames x 12 bytes", burst.count, 16 * 12)
    check("burst first frame = index 0x0b", hex(burst.prefix(12)), "4816efbe040000000b000000")
    check("burst last frame = index 0x0c", hex(burst.suffix(12)), "4816efbe040000000c000000")

    var expected = Data()
    for idx in Helm.subscribeIndices { expected.append(Helm.subscribeFrame(index: idx)) }
    check("burst matches frozen index order", hex(burst), hex(expected))
}

// MARK: - Inbound parsing (SPEC §4.4–§4.5)

section("Inbound parsing")

do {
    // CONTEXT payload = [u32 LE 1][u32 LE ctx_id] — ctx_id is the SECOND u32.
    let payload = Data([0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
    let inbound = Helm.parse(HelmFrame(type: Helm.CONTEXT, payload: payload))
    expectTrue("CONTEXT uses the second u32 as ctx_id", inbound == .context(5))
}

/// EVENT payload = [u32 LE subtype][u32 LE len][data]
func eventPayload(subtype: UInt32, body: [UInt8]) -> Data {
    var out = [UInt8]()
    out += withUnsafeBytes(of: subtype.littleEndian) { Array($0) }
    out += withUnsafeBytes(of: UInt32(body.count).littleEndian) { Array($0) }
    out += body
    return Data(out)
}

do {
    let url = "rtsp://172.16.6.0:554/helm_1280x720.h264"
    let inbound = Helm.parse(HelmFrame(type: Helm.EVENT,
                                       payload: eventPayload(subtype: 0, body: Array(url.utf8))))
    expectTrue("EVENT subtype 0 -> RTSP URL", inbound == .rtspURL(url))

    let withNUL = Array(url.utf8) + [0x00]
    let inbound2 = Helm.parse(HelmFrame(type: Helm.EVENT,
                                        payload: eventPayload(subtype: 0, body: withNUL)))
    expectTrue("EVENT subtype 0 trims trailing NUL", inbound2 == .rtspURL(url))

    let inbound3 = Helm.parse(HelmFrame(type: Helm.EVENT,
                                        payload: eventPayload(subtype: 1, body: [0xAA, 0xBB, 0xCC])))
    expectTrue("EVENT subtype 1 surfaced raw",
               inbound3 == .event(subtype: 1, data: Data([0xAA, 0xBB, 0xCC])))
}

// MARK: - Multi-URL EVENT (regression: real GPSMAP hardware, 2026-07-30)

section("Multiple RTSP URLs in one EVENT")

do {
    // Verbatim from a live plotter. It offers one URL per resolution in a single
    // payload; the first build glued them together and handed the blob to ffmpeg,
    // which failed with "Invalid data found when processing input".
    let host = "garmin-j6-kraken-3475525228.local"
    let hi = "rtsp://\(host):554/helm_1280x720.h264"
    let lo = "rtsp://\(host):554/helm_960x540.h264"

    for (label, sep) in [("NUL-separated", "\0"), ("newline-separated", "\n"), ("CRLF", "\r\n")] {
        let blob = hi + sep + lo + "\0"
        let found = Helm.rtspURLs(in: blob)
        check("\(label): finds both URLs", found.count, 2)
        expectTrue("\(label): picks the 1280x720 one",
                   Helm.preferredRTSPURL(from: found) == hi)

        let inbound = Helm.parse(HelmFrame(type: Helm.EVENT,
                                           payload: eventPayload(subtype: 0, body: Array(blob.utf8))))
        expectTrue("\(label): EVENT parse yields only the best URL", inbound == .rtspURL(hi))
    }

    // Order must not matter — lower resolution listed first.
    let reversed = Helm.rtspURLs(in: lo + "\0" + hi)
    expectTrue("picks highest resolution regardless of order",
               Helm.preferredRTSPURL(from: reversed) == hi)

    // A single URL must still behave exactly as before.
    expectTrue("single URL unchanged", Helm.preferredRTSPURL(from: Helm.rtspURLs(in: hi)) == hi)

    // Junk around the URLs must not leak into the result.
    let messy = "  \(hi) \r\n \(lo) \0\0 "
    expectTrue("whitespace/NUL noise stripped",
               Helm.preferredRTSPURL(from: Helm.rtspURLs(in: messy)) == hi)

    // No rtsp:// at all -> nil, so the caller falls back rather than playing garbage.
    expectTrue("no URLs -> nil", Helm.preferredRTSPURL(from: Helm.rtspURLs(in: "not a url")) == nil)
}

// MARK: - mDNS host substitution (VLC on iOS cannot resolve .local)

section("Rewriting the RTSP host to a numeric IP")

do {
    let mdns = "rtsp://garmin-j6-kraken-3475525228.local:554/helm_1280x720.h264"
    check("swaps .local host for the IP, keeping port and path",
          Helm.rewritingHost(of: mdns, to: "172.16.6.0") ?? "nil",
          "rtsp://172.16.6.0:554/helm_1280x720.h264")

    check("works with no port",
          Helm.rewritingHost(of: "rtsp://plotter.local/helm.h264", to: "172.16.6.0") ?? "nil",
          "rtsp://172.16.6.0/helm.h264")

    check("works with no path",
          Helm.rewritingHost(of: "rtsp://plotter.local:554", to: "172.16.6.0") ?? "nil",
          "rtsp://172.16.6.0:554")

    check("an already-numeric host is harmless",
          Helm.rewritingHost(of: "rtsp://10.0.0.5:554/a.h264", to: "172.16.6.0") ?? "nil",
          "rtsp://172.16.6.0:554/a.h264")

    expectTrue("garbage input -> nil so the caller keeps the original",
               Helm.rewritingHost(of: "not-a-url", to: "172.16.6.0") == nil)

    // Numeric-IPv4 detection gates the substitution: never swap in a name.
    expectTrue("172.16.6.0 is numeric",   Helm.isNumericIPv4("172.16.6.0"))
    expectTrue("172.16.99.247 is numeric", Helm.isNumericIPv4("172.16.99.247"))
    expectTrue(".local name is not numeric",
               !Helm.isNumericIPv4("garmin-j6-kraken-3475525228.local"))
    expectTrue("300.1.1.1 is not numeric", !Helm.isNumericIPv4("300.1.1.1"))
    expectTrue("three octets is not numeric", !Helm.isNumericIPv4("172.16.6"))
    expectTrue("empty octet is not numeric", !Helm.isNumericIPv4("172..6.0"))

    // Extracting the host is what lets us resolve it ourselves when discovery
    // hands back a name rather than an address.
    check("host of a .local URL with port",
          Helm.hostComponent(of: mdns) ?? "nil", "garmin-j6-kraken-3475525228.local")
    check("host with no port",
          Helm.hostComponent(of: "rtsp://plotter.local/a.h264") ?? "nil", "plotter.local")
    check("host that is numeric",
          Helm.hostComponent(of: "rtsp://172.16.6.0:554/a.h264") ?? "nil", "172.16.6.0")
    check("bracketed IPv6 host",
          Helm.hostComponent(of: "rtsp://[fe80::1]:554/a.h264") ?? "nil", "fe80::1")
    expectTrue("garbage -> nil", Helm.hostComponent(of: "nonsense") == nil)
}

// MARK: - Touch encoding (SPEC §4.6)

section("Touch encoding (16.16 fixed point)")

check("fixed16_16(0.0)", HelmTouch.fixed16_16(0.0), 0)
check("fixed16_16(0.25)", HelmTouch.fixed16_16(0.25), 0x4000)
check("fixed16_16(0.5)", HelmTouch.fixed16_16(0.5), 0x8000)
check("fixed16_16(1.0) == unity 65536", HelmTouch.fixed16_16(1.0), 0x0001_0000)
check("fixed16_16(2.0) clamps high", HelmTouch.fixed16_16(2.0), 0x0001_0000)
check("fixed16_16(-1.0) clamps low", HelmTouch.fixed16_16(-1.0), 0)

do {
    let d = HelmTouch.encode(ctxId: 7,
                             points: [HelmTouchPoint(trackId: 0, nx: 0.5, ny: 0.25, down: true)])
    check("payload = 8-byte header + 16-byte point", d.count, 8 + 16)
}

check("TOUCH frame, centre press",
      hex(Helm.touch(ctxId: 5, points: [HelmTouchPoint(trackId: 0, nx: 0.5, ny: 0.5, down: true)])),
      "4c16efbe18000000050000000100000000008000000080000001000000000000")

check("TOUCH frame, centre release",
      hex(Helm.touch(ctxId: 5, points: [HelmTouchPoint(trackId: 0, nx: 0.5, ny: 0.5, down: false)])),
      "4c16efbe18000000050000000100000000008000000080000000000000000000")

// MARK: - Pairing (SPEC §4.8–§4.9)

section("Pairing protobuf + tag")

do {
    // MobileDeviceIdentity: field1 UUID text, field2 token as LEB128 varint,
    // field3 device name. 52 bytes total.
    let msg = Pairing.identityMessage(deviceId: "550e8400-e29b-41d4-a716-446655440000",
                                      token: 0x1122_3344,
                                      deviceName: "iPhone")
    let expected = "0a24"
        + "35353065383430302d653239622d343164342d613731362d343436363535343430303030"
        + "10c4e6888901"
        + "1a066950686f6e65"
    check("identity message length", msg.count, 52)
    check("identity message bytes", hex(msg), expected)
}

do {
    // The token is a varint in the protobuf, but 4 LE bytes in the <tag>.
    var w = ByteWriter()
    w.varint(UInt64(UInt32(0x1122_3344)))
    check("token as LEB128 varint", hex(w.data), "c4e6888901")
}

check("tag(0x11223344)", Pairing.tag(for: 0x1122_3344), "RDMiEQIBAAA")
check("tag length is 11 chars", Pairing.tag(for: 0x1122_3344).count, 11)

do {
    var allSafe = true
    for _ in 0..<200 {
        let tag = Pairing.tag(for: Pairing.makePathSafeToken())
        if tag.contains("+") || tag.contains("/") || tag.contains("=") || tag.count != 11 {
            allSafe = false
            break
        }
    }
    expectTrue("makePathSafeToken yields URL-path-safe tags (200 samples)", allSafe)
}

// =============================================================================
//  Native RTSP/RTP/H.264 player — the pure layer (SPEC-RTSP §8)
//
//  Everything below lives in Sources/RTSPCore/ and imports nothing but
//  Foundation, which is what lets these vectors run with no Xcode at all.
// =============================================================================

// MARK: - RTSP requests (SPEC-RTSP §8.1)

section("RTSP requests")

do {
    let full = "rtsp://172.16.6.155:554/helm_1280x720.h264"

    checkWire("OPTIONS serialization",
              RTSPRequestBuilder.options(uri: full, cseq: 1, session: nil).serialized(),
              "OPTIONS \(full) RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: HelmMirror/1.0\r\n\r\n")

    checkWire("DESCRIBE serialization",
              RTSPRequestBuilder.describe(uri: "rtsp://h/s", cseq: 2).serialized(),
              "DESCRIBE rtsp://h/s RTSP/1.0\r\nCSeq: 2\r\n"
              + "Accept: application/sdp\r\nUser-Agent: HelmMirror/1.0\r\n\r\n")

    checkWire("SETUP over UDP",
              RTSPRequestBuilder.setupUDP(uri: "rtsp://h/s/track1", cseq: 3,
                                          clientRTPPort: 51000).serialized(),
              "SETUP rtsp://h/s/track1 RTSP/1.0\r\nCSeq: 3\r\n"
              + "Transport: RTP/AVP;unicast;client_port=51000-51001\r\n"
              + "User-Agent: HelmMirror/1.0\r\n\r\n")

    checkWire("SETUP over interleaved TCP",
              RTSPRequestBuilder.setupTCP(uri: "rtsp://h/s/track1", cseq: 3,
                                          rtpChannel: 0, rtcpChannel: 1).serialized(),
              "SETUP rtsp://h/s/track1 RTSP/1.0\r\nCSeq: 3\r\n"
              + "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"
              + "User-Agent: HelmMirror/1.0\r\n\r\n")

    checkWire("PLAY serialization",
              RTSPRequestBuilder.play(uri: "rtsp://h/s/", cseq: 4,
                                      session: "8FE3A1B2").serialized(),
              "PLAY rtsp://h/s/ RTSP/1.0\r\nCSeq: 4\r\nSession: 8FE3A1B2\r\n"
              + "Range: npt=0.000-\r\nUser-Agent: HelmMirror/1.0\r\n\r\n")

    // The two keepalive/shutdown requests are on the same wire path, so pin them too.
    checkWire("GET_PARAMETER keepalive",
              RTSPRequestBuilder.getParameter(uri: "rtsp://h/s/", cseq: 5,
                                              session: "8FE3A1B2").serialized(),
              "GET_PARAMETER rtsp://h/s/ RTSP/1.0\r\nCSeq: 5\r\nSession: 8FE3A1B2\r\n"
              + "User-Agent: HelmMirror/1.0\r\n\r\n")

    checkWire("TEARDOWN serialization",
              RTSPRequestBuilder.teardown(uri: "rtsp://h/s/", cseq: 6,
                                          session: "8FE3A1B2").serialized(),
              "TEARDOWN rtsp://h/s/ RTSP/1.0\r\nCSeq: 6\r\nSession: 8FE3A1B2\r\n"
              + "User-Agent: HelmMirror/1.0\r\n\r\n")

    // OPTIONS doubles as the keepalive once a session exists, and then it must
    // carry the id or the server ignores it and drops the session.
    checkWire("OPTIONS carries Session when given one",
              RTSPRequestBuilder.options(uri: "rtsp://h/s/", cseq: 7,
                                         session: "8FE3A1B2").serialized(),
              "OPTIONS rtsp://h/s/ RTSP/1.0\r\nCSeq: 7\r\nSession: 8FE3A1B2\r\n"
              + "User-Agent: HelmMirror/1.0\r\n\r\n")

    // wireText is what reaches the on-screen log: same text, LF, no blank line.
    check("wireText uses LF and drops the blank line",
          escaped(RTSPRequestBuilder.describe(uri: "rtsp://h/s", cseq: 2).wireText),
          escaped("DESCRIBE rtsp://h/s RTSP/1.0\nCSeq: 2\n"
                  + "Accept: application/sdp\nUser-Agent: HelmMirror/1.0"))
}

// MARK: - RTSP responses (SPEC-RTSP §8.2)

section("RTSP responses")

/// Decode one complete response out of a canned message. Returns nil on a throw
/// or a short read, both of which the vectors assert on separately.
func responseItem(_ s: String) -> (response: RTSPResponse, consumed: Int)? {
    // `try?` already flattens the decoder's Optional return, so this is one
    // unwrap, not two.
    guard let (item, consumed) = try? RTSPWireDecoder.decode(Array(s.utf8)),
          case .response(let response) = item else { return nil }
    return (response, consumed)
}

do {
    let a = "RTSP/1.0 200 OK\r\n"
        + "CSeq: 2\r\n"
        + "Content-Base: rtsp://172.16.6.155:554/helm_1280x720.h264/\r\n"
        + "Content-Type: application/sdp\r\n"
        + "Content-Length: 5\r\n"
        + "\r\n"
        + "hello"

    if let (response, consumed) = responseItem(a) {
        check("status code", response.statusCode, 200)
        check("reason phrase", response.reasonPhrase, "OK")
        check("CSeq", response.cseq ?? -1, 2)
        check("Content-Base", response.header("content-base") ?? "nil",
              "rtsp://172.16.6.155:554/helm_1280x720.h264/")
        check("header lookup is case-insensitive",
              response.header("Content-Type") ?? "nil", "application/sdp")
        check("Content-Length", response.contentLength, 5)
        check("body", String(decoding: response.body, as: UTF8.self), "hello")
        check("consumed the whole message", consumed, a.utf8.count)
        expectTrue("200 is a success", response.isSuccess)
    } else {
        failed += 1; print("  ✗ response A did not decode")
    }

    // One byte short of the declared body: the decoder must wait, not guess.
    let truncated = String(a.dropLast())
    var truncatedIsNil = false
    do { truncatedIsNil = try RTSPWireDecoder.decode(Array(truncated.utf8)) == nil } catch { }
    expectTrue("a body one byte short -> nil", truncatedIsNil)

    if let (_, consumed) = responseItem("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n") {
        check("head-only response consumes 28 bytes", consumed, 28)
    } else {
        failed += 1; print("  ✗ head-only response did not decode")
    }

    if let (_, consumed) = responseItem("RTSP/1.0 200 OK\nCSeq: 1\n\n") {
        check("LF-only head consumes 25 bytes", consumed, 25)
    } else {
        failed += 1; print("  ✗ LF-only response did not decode")
    }
}

do {
    if let (response, _) = responseItem("RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 8FE3A1B2;timeout=60\r\n\r\n") {
        check("session id", response.sessionId ?? "nil", "8FE3A1B2")
        check("session timeout", response.sessionTimeout ?? -1, 60)
    } else {
        failed += 1; print("  ✗ Session response did not decode")
    }

    if let (response, _) = responseItem("RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: ABC\r\n\r\n") {
        check("session id without timeout", response.sessionId ?? "nil", "ABC")
        expectTrue("absent timeout is nil", response.sessionTimeout == nil)
    } else {
        failed += 1; print("  ✗ Session-without-timeout response did not decode")
    }
}

do {
    if let (response, _) = responseItem("RTSP/1.0 461 Unsupported transport\r\nCSeq: 3\r\n\r\n") {
        check("461 status code", response.statusCode, 461)
        check("461 reason phrase", response.reasonPhrase, "Unsupported transport")
        expectTrue("461 is not a success", !response.isSuccess)
    } else {
        failed += 1; print("  ✗ 461 response did not decode")
    }

    // Guard rail: without checking the version token, an HTTP status line would
    // silently decode as a server request for the method "HTTP/1.1".
    var threwMalformedRequest = false
    do {
        _ = try RTSPWireDecoder.decode(Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
    } catch let error as RTSPParseError {
        threwMalformedRequest = (error == .malformedRequestLine)
    } catch { }
    expectTrue("an HTTP status line throws .malformedRequestLine", threwMalformedRequest)

    if let (item, _) = try? RTSPWireDecoder.decode(Array("OPTIONS rtsp://x RTSP/1.0\r\nCSeq: 7\r\n\r\n".utf8)),
       case .request(let request) = item {
        check("server request method", request.method, "OPTIONS")
        check("server request uri", request.uri, "rtsp://x")
        check("server request CSeq", request.cseq ?? -1, 7)
    } else {
        failed += 1; print("  ✗ server-initiated OPTIONS did not decode as a request")
    }
}

// MARK: - RTSP interleaved framing (SPEC-RTSP §8.3)

section("RTSP interleaved framing")

func interleavedItem(_ raw: [UInt8], from start: Int = 0) -> (frame: RTSPInterleavedFrame, consumed: Int)? {
    guard let (item, consumed) = try? RTSPWireDecoder.decode(raw, from: start),
          case .interleaved(let frame) = item else { return nil }
    return (frame, consumed)
}

do {
    if let (frame, consumed) = interleavedItem([0x24, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]) {
        check("interleaved channel", Int(frame.channel), 0)
        check("interleaved payload", hex(frame.payload), "deadbeef")
        check("interleaved consumed", consumed, 8)
    } else {
        failed += 1; print("  ✗ complete $ frame did not decode")
    }

    var incompleteIsNil = false
    do { incompleteIsNil = try RTSPWireDecoder.decode([0x24, 0x01, 0x00, 0x02, 0xAA]) == nil } catch { }
    expectTrue("incomplete $ frame -> nil", incompleteIsNil)

    if let (frame, consumed) = interleavedItem([0x24, 0x00, 0x00, 0x00]) {
        check("zero-length $ frame payload", hex(frame.payload), "")
        check("zero-length $ frame consumed", consumed, 4)
    } else {
        failed += 1; print("  ✗ zero-length $ frame did not decode")
    }

    // Mixed stream: a binary frame and a text message share one octet stream,
    // which is the whole reason they share a decoder.
    var mixed: [UInt8] = [0x24, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]
    mixed += Array("RTSP/1.0 200 OK\r\nCSeq: 9\r\n\r\n".utf8)
    if let (frame, first) = interleavedItem(mixed) {
        check("mixed: first item is the $ frame", hex(frame.payload), "deadbeef")
        check("mixed: first consumed", first, 8)
        if let (item, second) = try? RTSPWireDecoder.decode(mixed, from: first),
           case .response(let response) = item {
            check("mixed: second item is the response", response.cseq ?? -1, 9)
            check("mixed: second consumed", second, 28)
            check("mixed: stream fully drained", first + second, mixed.count)
        } else {
            failed += 1; print("  ✗ mixed: response after the $ frame did not decode")
        }
    } else {
        failed += 1; print("  ✗ mixed: $ frame did not decode")
    }
}

// MARK: - RTSP Transport header (SPEC-RTSP §8.4)

section("RTSP Transport header")

do {
    let udp = RTSPTransportHeader.parse(
        "RTP/AVP;unicast;client_port=51000-51001;server_port=6970-6971;ssrc=1A2B3C4D")
    expectTrue("UDP transport is not interleaved", !udp.isTCPInterleaved)
    check("client RTP port", Int(udp.clientRTPPort ?? 0), 51000)
    check("client RTCP port", Int(udp.clientRTCPPort ?? 0), 51001)
    check("server RTP port", Int(udp.serverRTPPort ?? 0), 6970)
    check("server RTCP port", Int(udp.serverRTCPPort ?? 0), 6971)
    check("ssrc parsed as hex", udp.ssrc ?? 0, UInt32(0x1A2B3C4D))

    let tcp = RTSPTransportHeader.parse("RTP/AVP/TCP;unicast;interleaved=0-1")
    expectTrue("TCP transport is interleaved", tcp.isTCPInterleaved)
    check("rtp channel", Int(tcp.rtpChannel ?? 9), 0)
    check("rtcp channel", Int(tcp.rtcpChannel ?? 9), 1)
    expectTrue("interleaved transport has no server_port", tcp.serverRTPPort == nil)

    // A single port implies its odd partner, and `source=` is kept verbatim.
    let single = RTSPTransportHeader.parse("RTP/AVP;unicast;source=172.16.6.155;client_port=9244")
    check("source", single.source ?? "nil", "172.16.6.155")
    check("lone client port", Int(single.clientRTPPort ?? 0), 9244)
    check("implied client RTCP port", Int(single.clientRTCPPort ?? 0), 9245)

    let garbage = RTSPTransportHeader.parse("nonsense")
    expectTrue("garbage: not interleaved", !garbage.isTCPInterleaved)
    expectTrue("garbage: every port nil",
               garbage.clientRTPPort == nil && garbage.serverRTPPort == nil
               && garbage.rtpChannel == nil && garbage.ssrc == nil && garbage.source == nil)
}

// MARK: - SDP (SPEC-RTSP §8.5)

section("SDP")

let sdpFixture = """
v=0
o=- 1234567890 1 IN IP4 172.16.6.155
s=H.264 Video, streamed by HelmMirror
t=0 0
a=control:*
m=video 0 RTP/AVP 96
c=IN IP4 0.0.0.0
b=AS:4000
a=rtpmap:96 H264/90000
a=fmtp:96 packetization-mode=1;profile-level-id=42E01E;sprop-parameter-sets=Z0LgHtoBQBboQAAAAwBAAAAMoeMGVA==,aM48gA==
a=control:track1
"""

do {
    let sdp = SessionDescription.parse(sdpFixture)
    check("one media section", sdp.media.count, 1)
    if let video = sdp.media.first {
        check("media type", video.mediaType, "video")
        check("media port", video.port, 0)
        check("media proto", video.proto, "RTP/AVP")
        check("media formats", video.formats.map(String.init).joined(separator: ","), "96")
        check("media control", video.control ?? "nil", "track1")
        check("rtpmap for 96", video.rtpmap(for: 96) ?? "nil", "H264/90000")

        let fmtp = video.fmtp(for: 96) ?? ""
        check("fmtp packetization-mode",
              SDPH264.fmtpValue("packetization-mode", in: fmtp) ?? "nil", "1")
        check("fmtp profile-level-id is case-insensitive",
              SDPH264.fmtpValue("PROFILE-LEVEL-ID", in: fmtp) ?? "nil", "42E01E")
        expectTrue("absent fmtp key -> nil", SDPH264.fmtpValue("nope", in: fmtp) == nil)
    } else {
        failed += 1; print("  ✗ no media section parsed")
    }
    check("session-level control", sdp.sessionControl ?? "nil", "*")

    if let track = SDPH264.h264Track(in: sdp) {
        check("h264 payload type", Int(track.payloadType), 96)
        check("h264 clock rate", track.clockRate, 90000)
        check("h264 packetization mode", track.packetizationMode, 1)
        check("h264 sps count", track.sps.count, 1)
        check("h264 pps count", track.pps.count, 1)
        check("h264 control", track.control ?? "nil", "track1")
        check("sps bytes", hex(track.sps[0]),
              "6742e01eda014016e840000003004000000ca1e30654")
        check("sps is NAL type 7", Int(H264NAL.type(of: track.sps[0])), 7)
        check("pps bytes", hex(track.pps[0]), "68ce3c80")
        check("pps is NAL type 8", Int(H264NAL.type(of: track.pps[0])), 8)
    } else {
        failed += 1; print("  ✗ no H.264 track found in the fixture")
    }

    // Real servers omit the base64 padding; a strict decoder loses the PPS.
    let unpadded = SDPH264.parseSpropParameterSets("aM48gA")
    check("unpadded base64 still decodes", unpadded.pps.map(hex).joined(separator: ","), "68ce3c80")
    check("unpadded base64 yields no SPS", unpadded.sps.count, 0)
}

// MARK: - RTSP control URL joining (SPEC-RTSP §8.6)

section("RTSP control URL joining")

do {
    check("relative control appends",
          RTSPURL.resolve(control: "track1", base: "rtsp://h:554/s.h264"),
          "rtsp://h:554/s.h264/track1")
    check("relative control with a trailing slash on the base",
          RTSPURL.resolve(control: "track1", base: "rtsp://h:554/s.h264/"),
          "rtsp://h:554/s.h264/track1")
    check("absolute-path control replaces the path",
          RTSPURL.resolve(control: "/track1", base: "rtsp://h:554/s.h264"),
          "rtsp://h:554/track1")
    check("absolute-URL control wins outright",
          RTSPURL.resolve(control: "rtsp://other/z", base: "rtsp://h/s"),
          "rtsp://other/z")
    check("control '*' means the base",
          RTSPURL.resolve(control: "*", base: "rtsp://h/s"), "rtsp://h/s")
    check("no control means the base",
          RTSPURL.resolve(control: nil, base: "rtsp://h/s"), "rtsp://h/s")
    // Live555-style track names contain '='; nothing may escape them.
    check("trackID= style control",
          RTSPURL.resolve(control: "trackID=0", base: "rtsp://h:554/helm_1280x720.h264"),
          "rtsp://h:554/helm_1280x720.h264/trackID=0")

    if let (withBase, _) = responseItem("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Base: rtsp://h/s/\r\n\r\n"),
       let (without, _) = responseItem("RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n") {
        check("Content-Base wins over the request URI",
              RTSPURL.effectiveBase(requestURI: "rtsp://h/s", response: withBase), "rtsp://h/s/")
        check("no Content-Base falls back to the request URI",
              RTSPURL.effectiveBase(requestURI: "rtsp://h/s", response: without), "rtsp://h/s")
    } else {
        failed += 1; print("  ✗ effectiveBase fixtures did not decode")
    }
}

// MARK: - RTP header (SPEC-RTSP §8.7)

section("RTP header")

do {
    if let p = RTPPacket.parse(bytes("80 60 002A 0001E240 DEADBEEF 6742E01E")) {
        expectTrue("marker clear", !p.hasMarker)
        check("payload type", Int(p.payloadType), 96)
        check("sequence number", Int(p.sequenceNumber), 42)
        check("timestamp", p.timestamp, UInt32(123456))
        check("ssrc", p.ssrc, UInt32(0xDEADBEEF))
        check("payload", hex(p.payload), "6742e01e")
    } else {
        failed += 1; print("  ✗ plain RTP packet did not parse")
    }

    if let p = RTPPacket.parse(bytes("80 E0 002A 0001E240 DEADBEEF AA")) {
        expectTrue("marker set", p.hasMarker)
        check("marker packet payload type", Int(p.payloadType), 96)
        check("marker packet payload", hex(p.payload), "aa")
    } else {
        failed += 1; print("  ✗ marker RTP packet did not parse")
    }

    if let p = RTPPacket.parse(bytes("A0 60 002A 0001E240 DEADBEEF AA 000003")) {
        check("padding stripped", hex(p.payload), "aa")
    } else {
        failed += 1; print("  ✗ padded RTP packet did not parse")
    }

    if let p = RTPPacket.parse(bytes("90 60 002A 0001E240 DEADBEEF BEDE0001 11223344 AABB")) {
        check("header extension skipped", hex(p.payload), "aabb")
    } else {
        failed += 1; print("  ✗ extended RTP packet did not parse")
    }

    if let p = RTPPacket.parse(bytes("82 60 002A 0001E240 DEADBEEF 11111111 22222222 AA")) {
        check("CSRC list skipped", hex(p.payload), "aa")
    } else {
        failed += 1; print("  ✗ RTP packet with CSRCs did not parse")
    }

    expectTrue("version 1 rejected",
               RTPPacket.parse(bytes("40 60 002A 0001E240 DEADBEEF AA")) == nil)
    expectTrue("11-byte packet rejected",
               RTPPacket.parse(bytes("80 60 002A 0001E240 DEADBE")) == nil)
    expectTrue("padding longer than the payload rejected",
               RTPPacket.parse(bytes("A0 60 002A 0001E240 DEADBEEF FF")) == nil)

    check("delta(0, 65535)", RTPSeq.delta(0, 65535), 1)
    check("delta(65535, 0)", RTPSeq.delta(65535, 0), -1)
    check("delta(5, 5)", RTPSeq.delta(5, 5), 0)
    expectTrue("0 is newer than 65535", RTPSeq.isNewer(0, than: 65535))
    expectTrue("65535 is not newer than 0", !RTPSeq.isNewer(65535, than: 0))
}

// MARK: - RTP reorder buffer (SPEC-RTSP §8.8)

section("RTP reorder buffer")

/// Build a real 12-byte RTP header + payload and parse it back, so the buffer is
/// exercised through the same path the socket uses.
func rtp(seq: UInt16, ts: UInt32 = 9000, marker: Bool = false,
         payload: String = "aa", ssrc: UInt32 = 0xDEADBEEF) -> RTPPacket {
    var raw = [UInt8]()
    raw.append(0x80)
    raw.append(marker ? 0xE0 : 0x60)
    raw.append(UInt8(truncatingIfNeeded: seq >> 8))
    raw.append(UInt8(truncatingIfNeeded: seq))
    for shift in [24, 16, 8, 0] { raw.append(UInt8(truncatingIfNeeded: ts >> UInt32(shift))) }
    for shift in [24, 16, 8, 0] { raw.append(UInt8(truncatingIfNeeded: ssrc >> UInt32(shift))) }
    raw += bytes(payload)
    guard let packet = RTPPacket.parse(raw) else {
        fatalError("the vector builder itself produced an unparseable packet")
    }
    return packet
}

func seqs(_ output: RTPReorderBuffer.Output) -> String {
    output.packets.map { String($0.sequenceNumber) }.joined(separator: ",")
}

do {
    var buffer = RTPReorderBuffer()
    check("in order: 100", seqs(buffer.push(rtp(seq: 100))), "100")
    check("in order: 101", seqs(buffer.push(rtp(seq: 101))), "101")
    check("in order: 102", seqs(buffer.push(rtp(seq: 102))), "102")
    check("in order: nothing lost", buffer.stats.lost, 0)
}

do {
    var buffer = RTPReorderBuffer()
    check("reorder: 100 delivers", seqs(buffer.push(rtp(seq: 100))), "100")
    check("reorder: 102 is held", seqs(buffer.push(rtp(seq: 102))), "")
    check("reorder: 101 releases both", seqs(buffer.push(rtp(seq: 101))), "101,102")
    check("reorder: nothing lost", buffer.stats.lost, 0)
}

do {
    var buffer = RTPReorderBuffer()
    _ = buffer.push(rtp(seq: 100))
    _ = buffer.push(rtp(seq: 102))
    let flushed = buffer.flush()
    check("flush delivers the held packet", seqs(flushed), "102")
    check("flush reports the gap", flushed.lost, 1)
    check("flush counts the loss in stats", buffer.stats.lost, 1)
}

do {
    var buffer = RTPReorderBuffer()
    _ = buffer.push(rtp(seq: 100))
    _ = buffer.push(rtp(seq: 101))
    check("duplicate delivers nothing", seqs(buffer.push(rtp(seq: 100))), "")
    check("duplicate is counted", buffer.stats.duplicates, 1)
}

do {
    var buffer = RTPReorderBuffer()
    check("wrap: 65535", seqs(buffer.push(rtp(seq: 65535))), "65535")
    check("wrap: 0", seqs(buffer.push(rtp(seq: 0))), "0")
    check("wrap: 1", seqs(buffer.push(rtp(seq: 1))), "1")
    check("wrap: nothing lost across the wrap", buffer.stats.lost, 0)
}

do {
    // Over capacity the buffer must give up on the gap rather than stall forever.
    var buffer = RTPReorderBuffer(capacity: 2)
    _ = buffer.push(rtp(seq: 100))
    _ = buffer.push(rtp(seq: 102))
    _ = buffer.push(rtp(seq: 103))
    let drained = buffer.push(rtp(seq: 104))
    check("capacity exceeded drains in order", seqs(drained), "102,103,104")
    check("capacity exceeded reports the gap", drained.lost, 1)
}

do {
    // A new SSRC is a new stream: the old position must not manufacture loss.
    var buffer = RTPReorderBuffer()
    _ = buffer.push(rtp(seq: 100, ssrc: 0x11111111))
    let restarted = buffer.push(rtp(seq: 200, ssrc: 0x22222222))
    check("SSRC change restarts the stream", seqs(restarted), "200")
    check("SSRC change reports no loss", restarted.lost, 0)
    check("SSRC change records no loss in stats", buffer.stats.lost, 0)
}

// MARK: - H.264 depacketization (SPEC-RTSP §8.9)

section("H.264 depacketization")

let spsHex = "6742e01eda014016e840000003004000000ca1e30654"
let ppsHex = "68ce3c80"
let stapAHex = "780016" + spsHex + "0004" + ppsHex

do {
    switch H264RTPPayload.classify(unhex("419a00")) {
    case .single(let nal): check("type 1 -> single NAL", hex(nal), "419a00")
    default: failed += 1; print("  ✗ 419a00 did not classify as a single NAL")
    }
    switch H264RTPPayload.classify(unhex("6742e01e")) {
    case .single(let nal): check("type 7 -> single NAL", hex(nal), "6742e01e")
    default: failed += 1; print("  ✗ 6742e01e did not classify as a single NAL")
    }

    if case .fuA(let fu)? = H264RTPPayload.classify(unhex("7c85aabb")) {
        expectTrue("FU-A start flag", fu.start)
        expectTrue("FU-A start is not the end", !fu.end)
        check("FU-A original NAL type", Int(fu.nalType), 5)
        check("FU-A nri", Int(fu.nri), 3)
        check("FU-A fragment", hex(fu.fragment), "aabb")
        check("FU-A reconstructed header", Int(fu.reconstructedHeader), 0x65)
    } else {
        failed += 1; print("  ✗ 7c85aabb did not classify as an FU-A start")
    }
    if case .fuA(let fu)? = H264RTPPayload.classify(unhex("7c05cc")) {
        expectTrue("FU-A middle: not start, not end", !fu.start && !fu.end)
        check("FU-A middle fragment", hex(fu.fragment), "cc")
    } else {
        failed += 1; print("  ✗ 7c05cc did not classify as an FU-A middle")
    }
    if case .fuA(let fu)? = H264RTPPayload.classify(unhex("7c45dd")) {
        expectTrue("FU-A end: not start, is end", !fu.start && fu.end)
        check("FU-A end fragment", hex(fu.fragment), "dd")
    } else {
        failed += 1; print("  ✗ 7c45dd did not classify as an FU-A end")
    }

    expectTrue("empty payload -> nil", H264RTPPayload.classify(Data()) == nil)
    expectTrue("FU-A with no FU header -> nil", H264RTPPayload.classify(unhex("7c")) == nil)
    if case .unsupported(let type)? = H264RTPPayload.classify(unhex("5900")) {
        check("type 25 is unsupported", Int(type), 25)
    } else {
        failed += 1; print("  ✗ 5900 did not classify as unsupported")
    }
}

do {
    if let nals = H264RTPPayload.splitSTAPA(unhex(stapAHex)) {
        check("STAP-A yields two NALs", nals.count, 2)
        check("STAP-A first NAL is the SPS", hex(nals[0]), spsHex)
        check("STAP-A second NAL is the PPS", hex(nals[1]), ppsHex)
    } else {
        failed += 1; print("  ✗ STAP-A did not split")
    }
    expectTrue("truncated STAP-A record -> nil",
               H264RTPPayload.splitSTAPA(unhex("780004" + "6742")) == nil)
    expectTrue("zero-size STAP-A record -> nil",
               H264RTPPayload.splitSTAPA(unhex("780000")) == nil)
}

do {
    check("avccPrefixed one NAL", hex(H264NAL.avccPrefixed([unhex("65aa")])), "0000000265aa")
    check("avccPrefixed two NALs",
          hex(H264NAL.avccPrefixed([unhex("67"), unhex("6801")])),
          "0000000167000000026801")
    let split = H264NAL.annexBToNALs(unhex("00000001" + "67aa" + "000001" + "68bb"))
    check("annexB split yields two NALs", split.map(hex).joined(separator: ","), "67aa,68bb")
    check("NAL type of an IDR slice", Int(H264NAL.type(of: unhex("65aa"))), 5)
    expectTrue("65aa is an IDR", H264NAL.isIDR(unhex("65aa")))
    expectTrue("6742 is a parameter set", H264NAL.isParameterSet(unhex("6742")))
}

/// Collect only the access units out of a batch of events.
func accessUnits(_ events: [H264Depacketizer.Event]) -> [H264AccessUnit] {
    events.compactMap { if case .accessUnit(let unit) = $0 { return unit } else { return nil } }
}

func parameterSetEvents(_ events: [H264Depacketizer.Event]) -> [H264ParameterSets] {
    events.compactMap { if case .parameterSets(let sets) = $0 { return sets } else { return nil } }
}

func dropEvents(_ events: [H264Depacketizer.Event]) -> [String] {
    events.compactMap { if case .dropped(let reason) = $0 { return reason } else { return nil } }
}

do {
    // 1. FU-A reassembly across three packets, closed by the marker bit.
    var depacketizer = H264Depacketizer()
    var events: [H264Depacketizer.Event] = []
    events += depacketizer.push(rtp(seq: 1, ts: 9000, payload: "7c85aabb"))
    events += depacketizer.push(rtp(seq: 2, ts: 9000, payload: "7c05cc"))
    events += depacketizer.push(rtp(seq: 3, ts: 9000, marker: true, payload: "7c45dd"))

    let units = accessUnits(events)
    check("FU-A produces exactly one access unit", units.count, 1)
    if let unit = units.first {
        check("FU-A access unit bytes", hex(unit.avcc), "0000000565aabbccdd")
        expectTrue("FU-A access unit is a keyframe", unit.isKeyframe)
        expectTrue("FU-A access unit is not corrupt", !unit.isCorrupt)
        check("FU-A access unit timestamp", unit.rtpTimestamp, UInt32(9000))
    }
}

do {
    // 2. A single NAL closed by the marker bit.
    var depacketizer = H264Depacketizer()
    let units = accessUnits(depacketizer.push(rtp(seq: 1, ts: 9000, marker: true, payload: "419a00")))
    check("single NAL produces one access unit", units.count, 1)
    if let unit = units.first {
        check("single NAL access unit bytes", hex(unit.avcc), "00000003419a00")
        expectTrue("a type-1 slice is not a keyframe", !unit.isKeyframe)
    }
}

do {
    // 3. Parameter sets are latched, never embedded in an access unit.
    var depacketizer = H264Depacketizer()
    let events = depacketizer.push(rtp(seq: 1, ts: 9000, payload: stapAHex))
    check("STAP-A emits one parameterSets event", parameterSetEvents(events).count, 1)
    check("STAP-A emits no access unit", accessUnits(events).count, 0)
    check("SPS latched", depacketizer.parameterSets.sps.count, 1)
    check("PPS latched", depacketizer.parameterSets.pps.count, 1)
    check("latched SPS bytes", hex(depacketizer.parameterSets.sps[0]), spsHex)
    check("latched PPS bytes", hex(depacketizer.parameterSets.pps[0]), ppsHex)
}

do {
    // 4. A timestamp change closes the previous picture even with no marker bit.
    var depacketizer = H264Depacketizer()
    let first = depacketizer.push(rtp(seq: 1, ts: 9000, payload: "419a00"))
    check("no marker, no boundary -> nothing yet", accessUnits(first).count, 0)

    let second = depacketizer.push(rtp(seq: 2, ts: 12000, payload: "419a00"))
    let closed = accessUnits(second)
    check("a new timestamp closes the previous AU", closed.count, 1)
    if let unit = closed.first {
        check("closed AU carries the OLD timestamp", unit.rtpTimestamp, UInt32(9000))
    }
    let flushed = accessUnits(depacketizer.flush())
    check("flush emits the last AU", flushed.count, 1)
    if let unit = flushed.first {
        check("flushed AU timestamp", unit.rtpTimestamp, UInt32(12000))
    }
}

do {
    // 5. Loss poisons the FU-A in flight: half a NAL must never reach the decoder.
    var depacketizer = H264Depacketizer()
    var events = depacketizer.push(rtp(seq: 1, ts: 9000, payload: "7c85aabb"))
    events += depacketizer.push(rtp(seq: 3, ts: 9000, marker: true, payload: "7c45dd"),
                                lostBefore: 2)
    expectTrue("loss emits a dropped event", !dropEvents(events).isEmpty)
    let units = accessUnits(events)
    expectTrue("no access unit is built from a broken fragment",
               units.allSatisfy { !hex($0.avcc).contains("aabb") })
}

do {
    // 6. An access unit with no decodable NAL is never emitted.
    var depacketizer = H264Depacketizer()
    let events = depacketizer.push(rtp(seq: 1, ts: 9000, marker: true, payload: "09f0"))
    check("an AUD alone produces no access unit", accessUnits(events).count, 0)
}

// MARK: - Recording and snapshots (SPEC-RECORDING §8)
//
// Everything below lives in Sources/RTSPCore/RecordingClock.swift — the file
// SPEC-RECORDING §1.1 calls `RecordingCore.swift` — and imports nothing but
// Foundation, so this harness still runs on a Mac with only the Command Line
// Tools. No AVFoundation, VideoToolbox, Photos, ImageIO, CoreMedia or UIKit
// type appears in a vector.

/// Renderings of the pure layer's enums. Comparing a rendered string rather
/// than an `==` gives a readable diff when a boundary moves.
func describe(_ outcome: RTPTimelineOutcome) -> String {
    switch outcome {
    case .first(let t):             return "first(\(t))"
    case .advanced(let t):          return "advanced(\(t))"
    case .coalesced(let t):         return "coalesced(\(t))"
    case .rejectedBackwards(let d): return "rejectedBackwards(\(d))"
    case .discontinuity(let d):     return "discontinuity(\(d))"
    }
}

func describe(_ decision: RecorderGateDecision) -> String {
    switch decision {
    case .write:              return "write"
    case .skip(let reason):   return "skip(\(reason))"
    case .finish(let reason): return "finish(\(reason))"
    }
}

func describe(_ refusal: RecordingStartRefusal?) -> String {
    guard let refusal else { return "nil" }
    switch refusal {
    case .insufficientSpace(let free, let required):
        return "insufficientSpace(\(free), \(required))"
    }
}

func describe(_ reason: RecordingStopReason?) -> String {
    guard let reason else { return "nil" }
    switch reason {
    case .user:               return "user"
    case .videoEnded:         return "videoEnded"
    case .backgrounded:       return "backgrounded"
    case .dismissed:          return "dismissed"
    case .reachedMaxDuration: return "reachedMaxDuration"
    case .reachedMaxSize:     return "reachedMaxSize"
    case .lowStorage(let free): return "lowStorage(\(free))"
    case .formatChanged:      return "formatChanged"
    case .noKeyframe:         return "noKeyframe"
    case .writerFailed(let d): return "writerFailed(\(d))"
    }
}

/// Every stop reason, so §8.4's 56/57/58 can be exhaustive rather than a sample.
let everyStopReason: [RecordingStopReason] = [
    .user, .videoEnded, .backgrounded, .dismissed,
    .reachedMaxDuration, .reachedMaxSize, .lowStorage(freeBytes: 1_234),
    .formatChanged, .noKeyframe,
    .writerFailed("disk I/O error"),
    .writerFailed(""),
    .writerFailed(String(repeating: "x", count: 400))
]

// MARK: Recording — RTP timeline (§8.1)

section("Recording — RTP timeline")

do {
    // 1-4. The ordinary case: rebased to zero, then straight 30 fps deltas.
    var timeline = RTPTimeline()
    check("fresh timeline rebases to zero", describe(timeline.push(9000)), "first(0)")
    check("+3000 advances", describe(timeline.push(12000)), "advanced(3000)")
    check("+3000 again", describe(timeline.push(15000)), "advanced(6000)")
    check("lastFrameDeltaTicks", String(timeline.lastFrameDeltaTicks), "3000")
}

do {
    // 5. The 32-bit RTP clock wraps every ~13 h 15 m; the unsigned difference
    //    reinterpreted as signed is the whole answer.
    var timeline = RTPTimeline()
    _ = timeline.push(0xFFFF_F000)
    check("wraparound is a small forward delta",
          describe(timeline.push(0x0000_1000)), "advanced(8192)")
}

do {
    // 6. The exact boundary.
    var timeline = RTPTimeline()
    _ = timeline.push(0xFFFF_FFFF)
    check("wraparound at 0xFFFFFFFF -> 0", describe(timeline.push(0)), "advanced(1)")
}

do {
    // 7-9. A repeated timestamp is nudged one tick rather than dropped, and the
    //      stream stays strictly monotonic afterwards.
    var timeline = RTPTimeline()
    _ = timeline.push(9000)
    check("a duplicate timestamp coalesces", describe(timeline.push(9000)), "coalesced(1)")

    var second = RTPTimeline()
    _ = second.push(9000)
    _ = second.push(12000)
    check("duplicate after progress", describe(second.push(12000)), "coalesced(3001)")
    check("strictly monotonic after a coalesce",
          describe(second.push(15000)), "advanced(6001)")
}

do {
    // 10-12. Backwards is refused and changes nothing, so the next sane
    //        timestamp continues from where the file already is.
    var timeline = RTPTimeline()
    _ = timeline.push(9000)
    check("backwards is rejected", describe(timeline.push(6000)), "rejectedBackwards(3000)")
    check("a rejection leaves the timeline alone", String(timeline.lastEmittedTicks), "0")
    check("a valid push after a rejection still works",
          describe(timeline.push(12000)), "advanced(3000)")
}

do {
    // 13-15. Beyond 60 s the plotter's clock moved, not time.
    var timeline = RTPTimeline()
    _ = timeline.push(0)
    check("a 60 s + 1 tick jump is a discontinuity",
          describe(timeline.push(5_400_001)), "discontinuity(5400001)")
    check("a discontinuity leaves the timeline alone", String(timeline.lastEmittedTicks), "0")

    var inside = RTPTimeline()
    _ = inside.push(0)
    check("exactly 60 s is still a gap, not a discontinuity",
          describe(inside.push(5_400_000)), "advanced(5400000)")
}

do {
    // 16. 500 frames across the wrap: every one accepted, ticks strictly up.
    var timeline = RTPTimeline()
    var rtp: UInt32 = 0xFFFF_0000
    var previous: Int64 = -1
    var allAccepted = true
    var strictlyIncreasing = true
    var last: Int64 = -1
    for _ in 0..<500 {
        let outcome = timeline.push(rtp)
        guard let ticks = outcome.ticks else { allAccepted = false; break }
        if ticks <= previous { strictlyIncreasing = false }
        previous = ticks
        last = ticks
        rtp = rtp &+ 3000
    }
    expectTrue("500 pushes across the wrap are all accepted", allAccepted)
    expectTrue("500 pushes are strictly increasing", strictlyIncreasing)
    check("500 pushes land on 499 x 3000", String(last), "1497000")
}

do {
    // 17-19. The tail duration for endSession, clamped to 60...10 fps.
    var fresh = RTPTimeline()
    check("nominal frame duration defaults to 30 fps",
          String(fresh.nominalFrameDurationTicks), "3000")

    var fast = RTPTimeline()
    _ = fast.push(0)
    _ = fast.push(1000)
    check("a 1000-tick delta clamps up to 60 fps",
          String(fast.nominalFrameDurationTicks), "1500")

    var slow = RTPTimeline()
    _ = slow.push(0)
    _ = slow.push(20000)
    check("a 20000-tick delta clamps down to 10 fps",
          String(slow.nominalFrameDurationTicks), "9000")
}

do {
    // 20. reset() is a fresh origin, not a continuation.
    var timeline = RTPTimeline()
    _ = timeline.push(9000)
    _ = timeline.push(12000)
    timeline.reset()
    check("reset re-establishes the origin", describe(timeline.push(7)), "first(0)")
}

// MARK: Recording — keyframe gate (§8.2)

section("Recording — keyframe gate")

do {
    // 21-23. A file must open on a sync sample, and never on a corrupt one.
    var gate = RecorderGate()
    check("fresh gate skips a non-keyframe",
          describe(gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))),
          "skip(waiting for keyframe)")

    var corrupt = RecorderGate()
    check("fresh gate skips a corrupt keyframe",
          describe(corrupt.decide(.accessUnit(isKeyframe: true, isCorrupt: true))),
          "skip(corrupt frame)")

    var clean = RecorderGate()
    check("fresh gate writes a clean keyframe",
          describe(clean.decide(.accessUnit(isKeyframe: true, isCorrupt: false))),
          "write")
}

do {
    // 24-27. Mid-recording: a corrupt unit re-arms the keyframe gate, and the
    //        file resyncs at the next IDR rather than writing a hole.
    var gate = RecorderGate()
    _ = gate.decide(.accessUnit(isKeyframe: true, isCorrupt: false))
    gate.confirmWrite()
    check("a clean P-frame after a write is written",
          describe(gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))),
          "write")
    gate.confirmWrite()
    check("a corrupt unit mid-recording is skipped",
          describe(gate.decide(.accessUnit(isKeyframe: true, isCorrupt: true))),
          "skip(corrupt frame)")
    check("the next P-frame resyncs",
          describe(gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))),
          "skip(resyncing)")
    check("the next keyframe ends the resync",
          describe(gate.decide(.accessUnit(isKeyframe: true, isCorrupt: false))),
          "write")
}

do {
    // 28. Writer backpressure also re-arms the gate.
    var gate = RecorderGate()
    _ = gate.decide(.accessUnit(isKeyframe: true, isCorrupt: false))
    gate.confirmWrite()
    check("a busy writer is a skip", describe(gate.decide(.writerBusy)), "skip(writer busy)")
    check("and the next P-frame resyncs",
          describe(gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))),
          "skip(resyncing)")
}

do {
    // 29. So does a timeline rejection — AVAssetWriter would refuse the sample.
    var gate = RecorderGate()
    _ = gate.decide(.accessUnit(isKeyframe: true, isCorrupt: false))
    gate.confirmWrite()
    check("a rejected timestamp is a skip",
          describe(gate.decide(.timelineRejected)), "skip(timestamp out of order)")
    check("and the next keyframe recovers",
          describe(gate.decide(.accessUnit(isKeyframe: true, isCorrupt: false))),
          "write")
}

do {
    // 30-31. One avcC per track: new parameter sets end a file that has content
    //        and merely re-arm one that does not.
    var written = RecorderGate()
    _ = written.decide(.accessUnit(isKeyframe: true, isCorrupt: false))
    written.confirmWrite()
    check("new parameter sets end a written file",
          describe(written.decide(.parameterSetsChanged)), "finish(format changed)")

    var settling = RecorderGate()
    check("new parameter sets before any write only re-arm",
          describe(settling.decide(.parameterSetsChanged)), "skip(format settling)")
}

do {
    // 32. A "recording" that never produces a file is a bug the user cannot see;
    //     300 skipped units (~10 s at 30 fps) is where it gives up.
    var gate = RecorderGate()
    var three_hundredth = ""
    for i in 1...300 {
        let decision = gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))
        if i == 300 { three_hundredth = describe(decision) }
    }
    check("the 300th skipped unit is still a skip", three_hundredth, "skip(waiting for keyframe)")
    check("the 301st gives up",
          describe(gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))),
          "finish(no keyframe arrived)")
}

do {
    // 33-35. Bookkeeping.
    var gate = RecorderGate()
    _ = gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))
    _ = gate.decide(.accessUnit(isKeyframe: false, isCorrupt: false))
    expectTrue("skips accumulate", gate.skipsSinceLastWrite == 2)
    gate.confirmWrite()
    check("confirmWrite resets the skip count", gate.skipsSinceLastWrite, 0)

    var pending = RecorderGate()
    _ = pending.decide(.accessUnit(isKeyframe: true, isCorrupt: false))
    expectTrue("a .write decision alone does not set hasWritten", !pending.hasWritten)
    pending.confirmWrite()
    expectTrue("confirmWrite sets hasWritten", pending.hasWritten)

    pending.reset()
    expectTrue("reset clears hasWritten and re-arms the keyframe gate",
               !pending.hasWritten && pending.needsKeyframe)
}

// MARK: Recording — filenames (§8.3)

section("Recording — filenames")

// 2026-07-25T17:20:00Z.
let fixedInstant = Date(timeIntervalSince1970: 1_785_000_000)
let utc = TimeZone(secondsFromGMT: 0)!
let edt = TimeZone(secondsFromGMT: -14400)!

do {
    // 36-39. Deterministic, locale-free, and shifted by the caller's zone.
    check("timestamp component",
          RecordingNames.timestampComponent(fixedInstant, timeZone: utc),
          "2026-07-25-172000")
    check("video filename",
          RecordingNames.videoFilename(fixedInstant, timeZone: utc),
          "HelmMirror-2026-07-25-172000.mp4")
    check("still filename",
          RecordingNames.stillFilename(fixedInstant, timeZone: utc),
          "HelmMirror-2026-07-25-172000.jpg")
    check("timestamp component at UTC-4",
          RecordingNames.timestampComponent(fixedInstant, timeZone: edt),
          "2026-07-25-132000")
}

do {
    // 40-42. Two snapshots inside one second are entirely possible.
    let name = RecordingNames.videoFilename(fixedInstant, timeZone: utc)
    check("first collision", RecordingNames.unique(name, existing: [name]),
          "HelmMirror-2026-07-25-172000-2.mp4")
    check("second collision",
          RecordingNames.unique(name, existing: [name, "HelmMirror-2026-07-25-172000-2.mp4"]),
          "HelmMirror-2026-07-25-172000-3.mp4")
    check("no collision leaves the name alone",
          RecordingNames.unique(name, existing: []), name)
}

do {
    // 43. Filesystem- and URL-safe, in every zone, collided or not.
    let forbidden = Set("/\\:*?\"<>| ")
    var candidates: [String] = []
    for zone in [utc, edt, TimeZone(secondsFromGMT: 13 * 3600)!] {
        let video = RecordingNames.videoFilename(fixedInstant, timeZone: zone)
        let still = RecordingNames.stillFilename(fixedInstant, timeZone: zone)
        candidates.append(video)
        candidates.append(still)
        candidates.append(RecordingNames.unique(video, existing: [video]))
        candidates.append(RecordingNames.unique(still, existing: [still]))
    }
    expectTrue("no filename contains a reserved character or a space",
               candidates.allSatisfy { $0.allSatisfy { !forbidden.contains($0) } })
    expectTrue("every filename is prefixed HelmMirror-",
               candidates.allSatisfy { $0.hasPrefix("HelmMirror-") })
}

do {
    // 44-45. The elapsed readout. Truncated, never rounded, so the label never
    //        shows a time the file has not reached.
    let inputs: [TimeInterval] = [0, 7, 59, 60, 83, 599, 600, 3599, 3600, 3753]
    let expected = ["0:00", "0:07", "0:59", "1:00", "1:23",
                    "9:59", "10:00", "59:59", "1:00:00", "1:02:33"]
    for (seconds, want) in zip(inputs, expected) {
        check("elapsedLabel(\(Int(seconds)))", RecordingNames.elapsedLabel(seconds), want)
    }
    check("elapsedLabel(-5) clamps", RecordingNames.elapsedLabel(-5), "0:00")
    check("elapsedLabel(0.9) truncates", RecordingNames.elapsedLabel(0.9), "0:00")
}

// MARK: Recording — guards (§8.4)

section("Recording — guards")

let tenGiB: Int64 = 10_737_418_240
let threeGiB: Int64 = 3_221_225_472
let hundredMiB: Int64 = 104_857_600

do {
    // 46-48. Exactly 500 MiB is allowed; one byte less is a refusal the user can read.
    check("exactly 500 MiB starts",
          describe(RecordingGuards.canStart(freeBytes: 524_288_000)), "nil")
    check("one byte under refuses",
          describe(RecordingGuards.canStart(freeBytes: 524_287_999)),
          "insufficientSpace(524287999, 524288000)")
    check("the refusal reads as MB",
          RecordingGuards.canStart(freeBytes: 524_287_999)?.message ?? "",
          "Only 499 MB free — need 500 MB")
}

do {
    // 49-55. The three running guards and their precedence.
    check("just under 30 minutes keeps going",
          describe(RecordingGuards.stopReason(elapsed: 1799, bytesWritten: 1_000,
                                              freeBytes: tenGiB)), "nil")
    check("30 minutes stops",
          describe(RecordingGuards.stopReason(elapsed: 1800, bytesWritten: 1_000,
                                              freeBytes: tenGiB)), "reachedMaxDuration")
    check("2 GiB stops",
          describe(RecordingGuards.stopReason(elapsed: 1, bytesWritten: 2_147_483_648,
                                              freeBytes: tenGiB)), "reachedMaxSize")
    check("exactly 200 MiB free keeps going",
          describe(RecordingGuards.stopReason(elapsed: 1, bytesWritten: 1,
                                              freeBytes: 209_715_200)), "nil")
    check("one byte under 200 MiB stops",
          describe(RecordingGuards.stopReason(elapsed: 1, bytesWritten: 1,
                                              freeBytes: 209_715_199)),
          "lowStorage(209715199)")
    check("storage outranks size and duration",
          describe(RecordingGuards.stopReason(elapsed: 3600, bytesWritten: threeGiB,
                                              freeBytes: hundredMiB)),
          "lowStorage(104857600)")
    check("size outranks duration",
          describe(RecordingGuards.stopReason(elapsed: 3600, bytesWritten: threeGiB,
                                              freeBytes: tenGiB)), "reachedMaxSize")
}

do {
    // 56-58. What counts as a failure, and the message budget.
    let benign: [RecordingStopReason] = [.user, .videoEnded, .backgrounded, .dismissed]
    expectTrue("the four ordinary stops are not failures",
               benign.allSatisfy { !$0.isFailure })

    let failures: [RecordingStopReason] = [
        .reachedMaxDuration, .reachedMaxSize, .lowStorage(freeBytes: 1),
        .formatChanged, .noKeyframe, .writerFailed("boom")
    ]
    expectTrue("the six abnormal stops are failures", failures.allSatisfy { $0.isFailure })

    expectTrue("every stop message is 1...60 characters",
               everyStopReason.allSatisfy { (1...60).contains($0.message.count) })
    check("an empty writer detail still reads",
          RecordingStopReason.writerFailed("   ").message, "Recording failed")
}

do {
    // 59. The gate's reason strings go straight into a 110-character
    //     diagnostics line shared with the RTSP handshake.
    var reasons: [String] = []
    func collect(_ decision: RecorderGateDecision) {
        switch decision {
        case .write: break
        case .skip(let reason), .finish(let reason): reasons.append(reason)
        }
    }

    var fresh = RecorderGate()
    collect(fresh.decide(.accessUnit(isKeyframe: false, isCorrupt: false)))
    collect(fresh.decide(.accessUnit(isKeyframe: true, isCorrupt: true)))
    collect(fresh.decide(.parameterSetsChanged))
    collect(fresh.decide(.writerBusy))
    collect(fresh.decide(.timelineRejected))

    var running = RecorderGate()
    _ = running.decide(.accessUnit(isKeyframe: true, isCorrupt: false))
    running.confirmWrite()
    collect(running.decide(.accessUnit(isKeyframe: true, isCorrupt: true)))
    collect(running.decide(.accessUnit(isKeyframe: false, isCorrupt: false)))
    collect(running.decide(.parameterSetsChanged))

    var starved = RecorderGate()
    for _ in 0...301 {
        collect(starved.decide(.accessUnit(isKeyframe: false, isCorrupt: false)))
    }

    expectTrue("all eight gate reasons were exercised", Set(reasons).count == 8)
    expectTrue("every gate reason is at most 24 characters",
               reasons.allSatisfy { !$0.isEmpty && $0.count <= 24 })
}

// MARK: - Summary

print("\n" + String(repeating: "─", count: 46))
if failed == 0 {
    print("PASS — \(passed) vectors verified.")
    print(String(repeating: "─", count: 46))
    exit(0)
} else {
    print("FAIL — \(failed) failed, \(passed) passed.")
    print(String(repeating: "─", count: 46))
    exit(1)
}
