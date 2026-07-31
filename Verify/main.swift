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
