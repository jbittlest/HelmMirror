//
//  HelmWireTests.swift
//  HelmMirror
//
//  Byte-exact tests for the wire core. Foundation-only: runs on macOS via
//  `swift test` with no Xcode, no Simulator, no VLC. Every vector below is taken
//  verbatim from the frozen SPEC (§4 byte layouts, §8 vector table) and the
//  protocol research (Mrkvak/helm-linux, verified against a GPSMAP 923xsv).
//
//  Architect-owned / frozen: these are the local verification the human runs.
//  Imports are limited to XCTest + the Foundation-only HelmProtocol module.
//

import XCTest
@testable import HelmProtocol

// Lowercase, unseparated hex — the format used throughout the SPEC vector table.
private func hex(_ d: Data) -> String {
    d.map { String(format: "%02x", $0) }.joined()
}
private func hex<S: Sequence>(_ a: S) -> String where S.Element == UInt8 {
    a.map { String(format: "%02x", $0) }.joined()
}

final class HelmWireTests: XCTestCase {

    // MARK: - Frame envelope (§4.1)
    // Wire frame: [u16 type LE][u16 magic=0xBEEF LE][u32 length LE][payload].

    func testFrameHeaderByteLayout() {
        // Header is exactly 8 bytes: type (LE) | magic 0xBEEF (LE) | length (LE).
        // Use a distinctive payload length (6) so the length field is unambiguous.
        XCTAssertEqual(HelmFrame.magic, 0xBEEF)
        let payload = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        let bytes = Array(HelmFrame(type: Helm.TOUCH, payload: payload).encoded())

        // type 0x164C LE -> 4c 16
        XCTAssertEqual(hex(bytes[0..<2]), "4c16")
        // magic 0xBEEF LE -> ef be
        XCTAssertEqual(hex(bytes[2..<4]), "efbe")
        // length 6 LE -> 06 00 00 00
        XCTAssertEqual(hex(bytes[4..<8]), "06000000")
        // total frame = 8-byte header + payload
        XCTAssertEqual(bytes.count, 8 + payload.count)
    }

    func testFrameDecodeExtractsHeaderFields() {
        // Decoding the header must recover type and payload length exactly.
        let payload = Data([0x31, 0x95])
        let bytes = Array(HelmFrame(type: Helm.HELLO, payload: payload).encoded())
        guard let (frame, consumed) = HelmFrame.decode(bytes) else {
            return XCTFail("decode returned nil for a complete frame")
        }
        XCTAssertEqual(frame.type, Helm.HELLO)
        XCTAssertEqual(Array(frame.payload), [0x31, 0x95])
        XCTAssertEqual(consumed, bytes.count)
    }

    func testFrameDecodeNeedsFullBody() {
        // 8-byte header claims a 4-byte payload, but only 2 payload bytes present.
        let partial: [UInt8] = [0x48, 0x16, 0xef, 0xbe, 0x04, 0x00, 0x00, 0x00, 0x0b, 0x00]
        XCTAssertNil(HelmFrame.decode(partial))
    }

    func testFrameDecodeNeedsFullHeader() {
        // Fewer than 8 bytes cannot form a header.
        XCTAssertNil(HelmFrame.decode([0x48, 0x16, 0xef]))
    }

    func testFrameDecodeConsumesOnlyOneFrame() {
        // Reassembly contract: decode one frame, report exact bytes consumed.
        var stream = Array(Helm.acquire())                              // 8 bytes, empty payload
        stream.append(contentsOf: Array(Helm.subscribeFrame(index: 0x00)))
        guard let (first, consumed) = HelmFrame.decode(stream) else {
            return XCTFail("decode returned nil")
        }
        XCTAssertEqual(first.type, Helm.ACQUIRE)
        XCTAssertEqual(consumed, 8)

        // The remainder is a complete, independently decodable SUBSCRIBE frame.
        let rest = Array(stream[consumed...])
        guard let (second, consumed2) = HelmFrame.decode(rest) else {
            return XCTFail("decode of remainder returned nil")
        }
        XCTAssertEqual(second.type, Helm.SUBSCRIBE)
        XCTAssertEqual(consumed2, rest.count)
    }

    // MARK: - Handshake frame vectors (§4.3, §8 #1–#6)

    func testHelloFrame() {
        // type 0x083F, magic 0xBEEF, len 2, payload 31 95 (u16 LE 0x9531).
        XCTAssertEqual(hex(Helm.hello()), "3f08efbe020000003195")
    }

    func testTokenFrame() {
        // type 0x0AA9, len 8, payload = the 8 client bytes verbatim.
        let token: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(hex(Helm.token(token)), "a90aefbe08000000deadbeef01020304")
    }

    func testAcquireFrame() {
        // type 0x1644, empty payload.
        XCTAssertEqual(hex(Helm.acquire()), "4416efbe00000000")
    }

    func testSubscribeSingleFrames() {
        // type 0x1648, len 4, payload = u32 LE index.
        XCTAssertEqual(hex(Helm.subscribeFrame(index: 0x0b)), "4816efbe040000000b000000")
        XCTAssertEqual(hex(Helm.subscribeFrame(index: 0x00)), "4816efbe0400000000000000")
    }

    func testSubscribeBurstIs16FramesOf12Bytes() {
        // SUBSCRIBE is 16 separate frames (not one 16-byte blob), each 8+4 = 12 bytes.
        let burst = Helm.subscribeFrames()
        XCTAssertEqual(Helm.subscribeIndices.count, 16)
        XCTAssertEqual(burst.count, 16 * 12)                            // 192 bytes
        // First frame is index 0x0b, last is index 0x0c.
        XCTAssertEqual(hex(burst.prefix(12)), "4816efbe040000000b000000")
        XCTAssertEqual(hex(burst.suffix(12)), "4816efbe040000000c000000")
    }

    func testSubscribeBurstMatchesIndexOrder() {
        // The concatenated burst must equal per-index frames in the frozen order,
        // duplicates included (0x00, 0x01, 0x08, 0x0a each appear twice).
        var expected = Data()
        for idx in Helm.subscribeIndices { expected.append(Helm.subscribeFrame(index: idx)) }
        XCTAssertEqual(Helm.subscribeFrames(), expected)
    }

    // MARK: - Inbound parsing (§4.4, §4.5, §8 #10–#11)

    func testParseContextUsesSecondU32() {
        // CONTEXT payload = [u32 LE 1][u32 LE ctx_id]; ctx_id is the SECOND u32.
        let payload = Data([0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
        let inbound = Helm.parse(HelmFrame(type: Helm.CONTEXT, payload: payload))
        XCTAssertEqual(inbound, .context(5))
    }

    func testParseEventSubtype0RTSPURL() {
        // EVENT subtype 0 -> UTF-8 RTSP URL. Vector from §4.5.
        let url = "rtsp://172.16.6.0:554/helm_1280x720.h264"
        let urlBytes = Array(url.utf8)
        var w = ByteWriter()
        w.u32(0)                                                        // subtype 0
        w.u32(UInt32(urlBytes.count))                                   // 0x28 = 40
        w.raw(urlBytes)
        let inbound = Helm.parse(HelmFrame(type: Helm.EVENT, payload: w.data))
        XCTAssertEqual(inbound, .rtspURL(url))
    }

    func testParseEventSubtype0TrimsTrailingNUL() {
        // A NUL-terminated URL string must be trimmed to the clean URL.
        let url = "rtsp://172.16.6.0:554/helm_1280x720.h264"
        var urlBytes = Array(url.utf8)
        urlBytes.append(0x00)                                           // trailing NUL
        var w = ByteWriter()
        w.u32(0)
        w.u32(UInt32(urlBytes.count))
        w.raw(urlBytes)
        let inbound = Helm.parse(HelmFrame(type: Helm.EVENT, payload: w.data))
        XCTAssertEqual(inbound, .rtspURL(url))
    }

    func testParseEventSubtype1IsRawEvent() {
        // Non-zero subtypes are surfaced raw (v1 does not interpret inline H.264).
        var w = ByteWriter()
        w.u32(1)
        w.u32(3)
        w.raw([0xAA, 0xBB, 0xCC])
        let inbound = Helm.parse(HelmFrame(type: Helm.EVENT, payload: w.data))
        XCTAssertEqual(inbound, .event(subtype: 1, data: Data([0xAA, 0xBB, 0xCC])))
    }

    // MARK: - Touch fixed-point + payload (§4.6, §8 #7–#9)

    func testFixed16_16() {
        // Ceiling is 65536 (= TOUCH_UNITY), not 65535; clamp to [0, 65536].
        XCTAssertEqual(HelmTouch.fixed16_16(0.0), 0)
        XCTAssertEqual(HelmTouch.fixed16_16(0.25), 0x4000)             // 16384
        XCTAssertEqual(HelmTouch.fixed16_16(0.5), 0x8000)             // 32768
        XCTAssertEqual(HelmTouch.fixed16_16(1.0), 0x0001_0000)        // 65536 (unity)
        XCTAssertEqual(HelmTouch.fixed16_16(2.0), 0x0001_0000)        // clamped high
        XCTAssertEqual(HelmTouch.fixed16_16(-1.0), 0)                 // clamped low
    }

    func testTouchPointIs16Bytes() {
        // Payload = 8-byte (ctx,count) header + 16 bytes per point.
        let d = HelmTouch.encode(
            ctxId: 7,
            points: [HelmTouchPoint(trackId: 0, nx: 0.5, ny: 0.25, down: true)])
        XCTAssertEqual(d.count, 8 + 16)
    }

    func testTouchFrameCenterDown() {
        // ctx_id 5, single finger at (0.5, 0.5), down = 1. §8 #7.
        let frame = Helm.touch(
            ctxId: 5,
            points: [HelmTouchPoint(trackId: 0, nx: 0.5, ny: 0.5, down: true)])
        XCTAssertEqual(hex(frame),
            "4c16efbe18000000050000000100000000008000000080000001000000000000")
    }

    func testTouchFrameCenterRelease() {
        // Same point, down = 0 -> only the down field zeroes out. §8 #8.
        let frame = Helm.touch(
            ctxId: 5,
            points: [HelmTouchPoint(trackId: 0, nx: 0.5, ny: 0.5, down: false)])
        XCTAssertEqual(hex(frame),
            "4c16efbe18000000050000000100000000008000000080000000000000000000")
    }

    // MARK: - Pairing protobuf (§4.8, §8 #12–#13)

    func testIdentityMessageVector() {
        // MobileDeviceIdentity, hand-encoded, 52 bytes total.
        //   field1 (0a24 + 36 UTF-8 bytes of the UUID TEXT)
        //   field2 (10 + varint c4 e6 88 89 01)   <- varint, NOT 4 LE bytes
        //   field3 (1a06 + "iPhone" = 69 50 68 6f 6e 65)
        let msg = Pairing.identityMessage(
            deviceId: "550e8400-e29b-41d4-a716-446655440000",
            token: 0x1122_3344,
            deviceName: "iPhone")
        let expected =
            "0a24" +
            "35353065383430302d653239622d343164342d613731362d343436363535343430303030" +
            "10c4e6888901" +
            "1a066950686f6e65"
        XCTAssertEqual(msg.count, 52)
        XCTAssertEqual(hex(msg), expected)
    }

    func testTokenVarintEncoding() {
        // The token in the protobuf is a LEB128 varint: 0x11223344 -> c4 e6 88 89 01.
        // (Its 4-byte LE form 44 33 22 11 appears ONLY in the <tag>, never here.)
        var w = ByteWriter()
        w.varint(UInt64(UInt32(0x1122_3344)))
        XCTAssertEqual(hex(w.data), "c4e6888901")
    }

    // MARK: - Pairing <tag> (§4.9, §8 #14–#15)

    func testTagVector() {
        // tag = base64(token[4 LE] || 02 01 00 00), '=' stripped.
        // token 0x11223344 -> input 44 33 22 11 02 01 00 00 -> RDMiEQIBAAA= -> RDMiEQIBAAA.
        XCTAssertEqual(Pairing.tag(for: 0x1122_3344), "RDMiEQIBAAA")
    }

    func testTagIsElevenChars() {
        // The 8-byte input always yields 12 base64 chars ending in one '=',
        // so the stripped tag is 11 chars.
        XCTAssertEqual(Pairing.tag(for: 0x1122_3344).count, 11)
    }

    func testMakePathSafeToken() {
        // A path-safe token's tag must never contain '+', '/', or '='.
        for _ in 0..<200 {
            let t = Pairing.makePathSafeToken()
            let tag = Pairing.tag(for: t)
            XCTAssertFalse(tag.contains("+"), "tag contained '+': \(tag)")
            XCTAssertFalse(tag.contains("/"), "tag contained '/': \(tag)")
            XCTAssertFalse(tag.contains("="), "tag contained '=': \(tag)")
            XCTAssertEqual(tag.count, 11)
        }
    }
}
