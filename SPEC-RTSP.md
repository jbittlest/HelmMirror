# HelmMirror — Frozen Spec: Native RTSP/RTP/H.264 Player (v2.0)

**Status: FROZEN.** This document replaces MobileVLCKit with a native Swift player.
Implementers build the files in §4–§7 against the exact interfaces given here. Nothing
in `Sources/HelmProtocol.swift` may change.

---

## 0. Why this exists — the evidence

The Garmin protocol layer works against two real plotters. Discovery, HTTP pairing, the
TCP session on 51200 and the EVENT message carrying the RTSP URL all succeed. **Only
video playback fails, and it fails inside MobileVLCKit:**

```
[HelmMirror] try UDP rtsp://172.16.6.155:554/helm_1280x720.h264
[DBG] version 2016.10.21            <- live555
[DBG] connection error -36
[ERR] Failed to connect with rtsp://172.16.6.155:554/helm_1280x720.h264
... (repeats 3x, then:)
[DBG] no access_demux modules matched
[DBG] creating access: rtsp://...   <- VLC falls back to its RealMedia rtsp module
[DBG] net: connecting to 172.16.6.155 port 554
[DBG] connection succeeded (socket = 6)      <- plain TCP to 554 WORKS
[DBG] net: opening 0.0.0.0 datagram port 9244
[ERR] Failed to play RTSP session            <- wrong module, cannot play RTP
```

All four of `{1280x720, 960x540} × {UDP, TCP}` fail identically with `-36` in ~250 ms,
**before any RTSP request/response is exchanged.** Plain TCP to port 554 succeeds in the
same log. The same stream plays perfectly on macOS via `ffplay` (see `Bridge/HLSPipeline.swift`,
`play(rtspURL:)`), proving it is a standard RTSP/RTP/H.264 stream.

Conclusion: the network is fine, the plotter is fine, **live555-inside-MobileVLCKit is the
broken component.** We replace it with ~1400 lines of Swift over
Foundation + Network + CoreMedia + AVFoundation + UIKit. Zero third-party dependencies.

### 0.1 Known-good reference parameters

From `Bridge/HLSPipeline.swift`, the flags that are proven to work on this exact stream:

```
-fflags nobuffer -flags low_delay -rtsp_transport udp -i <url> -c:v copy -an
```

Read that as: **UDP transport, no re-encoding, no buffering, H.264 passthrough.** That is
precisely what this player does.

---

## 1. Scope

### In scope (v1 of the native player)

1. RTSP 1.0 over TCP: `OPTIONS → DESCRIBE → SETUP → PLAY`, CSeq, `Session:` tracking,
   keepalive on the session-timeout interval, `TEARDOWN` on stop.
2. SDP parsing: H.264 media track, payload type, `sprop-parameter-sets`, `a=control`.
3. RTP receive over **both** `RTP/AVP` (UDP, `client_port` pair) and
   `RTP/AVP/TCP` (`$`-interleaved on the RTSP socket). UDP first, automatic fallback to
   interleaved TCP.
4. RFC 6184 depacketization: single NAL, FU-A, STAP-A. Sequence reordering with a small
   jitter buffer and loss detection. Annex-B/NAL → AVCC (4-byte big-endian length prefix).
5. `CMVideoFormatDescription` from SPS/PPS — from the SDP **and** from in-band parameter
   sets, because the plotter may only send them in band.
6. Display via `AVSampleBufferDisplayLayer` with `DisplayImmediately`, no rate control.
7. Every step reported through the **existing** `MirrorPlaybackState` and logged to the
   **existing** `MirrorDiagnostics.shared`, including the literal RTSP request and
   response lines. That on-screen visibility is what solved the last three bugs; it is a
   hard requirement, not a nicety.

### Explicitly out of scope

- **Audio.** The plotter sends video only; ignore any non-video `m=` section.
- **RTSP Digest/Basic authentication.** The plotter needs none (`ffplay` connects with a
  bare URL). On `401` log the `WWW-Authenticate` header verbatim and fail with a clear
  message. Do not implement Digest.
- **RTSP over HTTP tunnelling**, RTP/AVPF, SRTP, multicast, RTCP sender reports,
  `PAUSE`/seeking, RTP header extensions beyond skipping them.
- **`VTDecompressionSession`.** `AVSampleBufferDisplayLayer` decodes internally. A VT path
  is a documented future hook (§9.3) but must not be written now.
- Changing anything in `Sources/HelmProtocol.swift`.

---

## 2. File map and module rules

Two new directories under `Sources/`. The split is **load-bearing**, not cosmetic:

| Directory | Imports allowed | Compiled into |
|---|---|---|
| `Sources/RTSPCore/` | `Foundation` **only** | the iOS app module **and** the SwiftPM `HelmProtocol` target |
| `Sources/RTSP/` | `Foundation`, `Network`, `CoreMedia`, `AVFoundation`, `UIKit` | the iOS app module only |

`swift run helmverify` must keep working on a Mac with only Command Line Tools. That is
only possible if every byte-level function lives in `RTSPCore` and never touches
`Network`, `UIKit`, `AVFoundation`, `CoreMedia`, or `MirrorDiagnostics`.

**`Sources/RTSPCore/*.swift` must not import anything but Foundation and must not log.**
They are pure functions and value types; they return results, callers log them.

### 2.1 New files

```
Sources/RTSPCore/RTSPMessage.swift        pure  RTSP request build, response parse, $-framing
Sources/RTSPCore/SDP.swift                pure  SDP parse, H.264 track, sprop, control-URL join
Sources/RTSPCore/RTPPacket.swift          pure  RTP header parse, seq arithmetic, reorder buffer
Sources/RTSPCore/H264Depacketizer.swift   pure  RFC 6184 -> AVCC access units

Sources/RTSP/RTSPClient.swift             Network  the RTSP conversation + interleaved demux
Sources/RTSP/RTPUDPTransport.swift        Network  the UDP RTP/RTCP sockets
Sources/RTSP/H264VideoView.swift          AVF/UIKit  AVSampleBufferDisplayLayer + format desc
Sources/RTSP/RTSPVideoSession.swift       glue     client + transport + depacketizer -> view
```

### 2.2 Modified files

```
Sources/MirrorPlayerView.swift   rewritten; touch code preserved byte-for-byte (§7)
Package.swift                    RTSPCore joins the HelmProtocol target; RTSP/ excluded
Verify/main.swift                +~70 new byte vectors (§8)
project.yml                      drop the CocoaPods comments
Podfile                          DELETED
README.md                        build steps lose `pod install`
.github/workflows/ios-build.yml  drop `pod install`; build -project not -workspace
```

### 2.3 Deleted

```
Podfile
Podfile.lock            (if present)
Pods/                   (if present)
HelmMirror.xcworkspace  (if present)
```

### 2.4 Exact `Package.swift` change

Only the `HelmProtocol` target changes:

```swift
.target(
    name: "HelmProtocol",
    path: "Sources",
    exclude: [
        "GarminDiscovery.swift",
        "HelmPairing.swift",
        "HelmSession.swift",
        "MirrorPlayerView.swift",
        "ContentView.swift",
        "HelmMirrorApp.swift",
        "Info.plist",
        "RTSP"                     // platform-only: Network / AVFoundation / UIKit
    ],
    sources: ["HelmProtocol.swift", "RTSPCore"]
),
```

`sources:` accepts a directory, so new `RTSPCore` files need no further manifest edits.
XcodeGen's `sources: - path: Sources` already recurses, so both new directories land in
the app target automatically — **do not** add them to `project.yml`.

Nothing in `RTSPCore` may say `import HelmProtocol`: in the app it is the same module, and
in SwiftPM it is the same module too.

### 2.5 New build command (CocoaPods is gone)

```sh
xcodegen generate
xcodebuild -project HelmMirror.xcodeproj -scheme HelmMirror \
  -destination 'id=AE53ACEB-A47C-583E-B64C-1CA0C37D269B' \
  DEVELOPMENT_TEAM=W93UVP5TF5 build
swift run helmverify        # must stay green, no Xcode required
```

---

## 3. The conversation this player has, end to end

Against the real plotter, with `rtsp://172.16.6.155:554/helm_1280x720.h264`:

```
> OPTIONS rtsp://172.16.6.155:554/helm_1280x720.h264 RTSP/1.0
> CSeq: 1
> User-Agent: HelmMirror/1.0
<
< RTSP/1.0 200 OK
< CSeq: 1
< Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER

> DESCRIBE rtsp://172.16.6.155:554/helm_1280x720.h264 RTSP/1.0
> CSeq: 2
> Accept: application/sdp
> User-Agent: HelmMirror/1.0
<
< RTSP/1.0 200 OK
< CSeq: 2
< Content-Base: rtsp://172.16.6.155:554/helm_1280x720.h264/
< Content-Type: application/sdp
< Content-Length: 512
<
< v=0 ... m=video 0 RTP/AVP 96 ... a=fmtp:96 ...sprop-parameter-sets=...  a=control:track1

> SETUP rtsp://172.16.6.155:554/helm_1280x720.h264/track1 RTSP/1.0
> CSeq: 3
> Transport: RTP/AVP;unicast;client_port=51000-51001
<
< RTSP/1.0 200 OK
< CSeq: 3
< Transport: RTP/AVP;unicast;client_port=51000-51001;server_port=6970-6971;ssrc=1A2B3C4D
< Session: 8FE3A1B2;timeout=60

> PLAY rtsp://172.16.6.155:554/helm_1280x720.h264/ RTSP/1.0
> CSeq: 4
> Session: 8FE3A1B2
> Range: npt=0.000-
<
< RTSP/1.0 200 OK
< RTP-Info: url=...;seq=42;rtptime=123456

  ... RTP flows to UDP 51000 ...

> GET_PARAMETER rtsp://.../ RTSP/1.0     (every timeout/2, min 5 s, max 25 s)
> CSeq: 5
> Session: 8FE3A1B2
```

Note `SPEC.md §4.11` records that this plotter answered `461 Unsupported transport` to
TCP-interleaved SETUP. That claim came from VLC, whose RTSP stack never actually completed
a handshake, so it is **unverified**. Implement the interleaved path fully anyway and let
the real response decide; a genuine `461` is handled as a normal fallback outcome (§6.5).

---

## 4. `Sources/RTSPCore/` — the pure layer (frozen interfaces)

Everything below is `public`. Every type is `Equatable` where stated so vectors can
compare it. No file in this directory imports anything but `Foundation`.

### 4.1 `RTSPMessage.swift`

```swift
import Foundation

// ---- Requests -------------------------------------------------------------

public struct RTSPRequest {
    public let method: String
    public let uri: String
    public let cseq: Int
    /// Ordered extra headers, emitted after CSeq and before User-Agent.
    public let headers: [(name: String, value: String)]
    public let body: Data?

    public init(method: String, uri: String, cseq: Int,
                headers: [(name: String, value: String)] = [],
                body: Data? = nil)

    /// The exact bytes to put on the wire. CRLF line endings, blank line terminator.
    public func serialized() -> Data

    /// The same text, for MirrorDiagnostics. Newlines are real "\n", no trailing blank line.
    public var wireText: String
}

public enum RTSPRequestBuilder {
    public static let userAgent = "HelmMirror/1.0"

    public static func options(uri: String, cseq: Int, session: String?) -> RTSPRequest
    public static func describe(uri: String, cseq: Int) -> RTSPRequest
    public static func setupUDP(uri: String, cseq: Int, clientRTPPort: UInt16) -> RTSPRequest
    public static func setupTCP(uri: String, cseq: Int,
                                rtpChannel: UInt8, rtcpChannel: UInt8) -> RTSPRequest
    public static func play(uri: String, cseq: Int, session: String) -> RTSPRequest
    public static func getParameter(uri: String, cseq: Int, session: String) -> RTSPRequest
    public static func teardown(uri: String, cseq: Int, session: String) -> RTSPRequest
}
```

**Serialization rules (frozen — vectors depend on them byte for byte):**

- Request line: `"\(method) \(uri) RTSP/1.0\r\n"`.
- Then `"CSeq: \(cseq)\r\n"`.
- Then each entry of `headers` as `"\(name): \(value)\r\n"`, in order.
- Then `"User-Agent: HelmMirror/1.0\r\n"`.
- If `body != nil`: `"Content-Length: \(body.count)\r\n"` immediately before the blank line.
- Then `"\r\n"`, then the body bytes.

Builder header contents, in this order:

| builder | headers (before User-Agent) |
|---|---|
| `options` | `Session: <id>` if `session != nil`, else none |
| `describe` | `Accept: application/sdp` |
| `setupUDP` | `Transport: RTP/AVP;unicast;client_port=<p>-<p+1>` |
| `setupTCP` | `Transport: RTP/AVP/TCP;unicast;interleaved=<a>-<b>` |
| `play` | `Session: <id>`, `Range: npt=0.000-` |
| `getParameter` | `Session: <id>` |
| `teardown` | `Session: <id>` |

`RTP/AVP` (not `RTP/AVP/UDP`) is deliberate: it is the RFC 2326 spelling and the most
widely accepted.

```swift
// ---- Responses ------------------------------------------------------------

public enum RTSPParseError: Error, Equatable {
    case malformedStatusLine
    case malformedRequestLine
    case badContentLength
    case headerSectionTooLarge      // > 64 KiB before a blank line
}

public struct RTSPResponse: Equatable {
    public let statusCode: Int
    public let reasonPhrase: String
    /// Keys lowercased and trimmed; on a repeat the LAST occurrence wins.
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String?   // name is lowercased internally
    public var isSuccess: Bool                      // 200 ..< 300
    public var cseq: Int?
    public var contentLength: Int                   // 0 when absent/unparseable
    /// "Session: 8FE3A1B2;timeout=60" -> "8FE3A1B2"
    public var sessionId: String?
    /// ...                            -> 60
    public var sessionTimeout: Int?
    /// "RTSP/1.0 200 OK"
    public var statusLine: String
    /// Status line + every header, one per line, for MirrorDiagnostics.
    public var headText: String
}

public struct RTSPServerRequest: Equatable {
    public let method: String
    public let uri: String
    public let cseq: Int?
    public let headers: [String: String]
}

public struct RTSPInterleavedFrame: Equatable {
    public let channel: UInt8
    public let payload: Data
}

public enum RTSPStreamItem: Equatable {
    case response(RTSPResponse)
    case request(RTSPServerRequest)          // server-initiated (OPTIONS, ANNOUNCE, ...)
    case interleaved(RTSPInterleavedFrame)
}

public enum RTSPWireDecoder {
    /// Decode exactly one item from `bytes[start...]`.
    /// Returns nil when more bytes are needed. Throws only on malformed framing.
    public static func decode(_ bytes: [UInt8], from start: Int = 0)
        throws -> (item: RTSPStreamItem, consumed: Int)?
}
```

**Decoder rules (frozen):**

1. If `bytes[start] == 0x24` (`$`): interleaved frame.
   Layout `[0x24][u8 channel][u16 BE length][length bytes]`. Need `4 + length` bytes or
   return nil. `consumed = 4 + length`.
2. Otherwise it is a text message. Find the header terminator: the first occurrence of
   `\r\n\r\n` (4 bytes) **or** `\n\n` (2 bytes), whichever starts earlier. If neither is
   present and more than 65536 bytes have accumulated, throw `.headerSectionTooLarge`;
   otherwise return nil.
3. Split the head on `\r\n` or `\n`. Fold continuation lines (a line starting with a space
   or tab) onto the previous header value with a single joining space.
4. First line starting with `RTSP/` ⇒ response. `RTSP/1.0 <int> <reason...>`; a
   non-integer status code throws `.malformedStatusLine`. Otherwise ⇒ server request:
   `<METHOD> <uri> RTSP/1.0`; fewer than 3 tokens throws `.malformedRequestLine`.
5. Header line: split at the first `:`; name lowercased + trimmed, value trimmed of
   spaces and tabs. A line with no `:` is ignored.
6. Body length = `Content-Length` (0 if absent). A negative or non-numeric value with a
   present header throws `.badContentLength`. Need `headEnd + bodyLength` bytes or return
   nil. `consumed = headEnd + bodyLength`.
7. Server requests are assumed to have no body.

```swift
// ---- Transport header -----------------------------------------------------

public struct RTSPTransportHeader: Equatable {
    public let raw: String
    public let isTCPInterleaved: Bool
    public let rtpChannel: UInt8?
    public let rtcpChannel: UInt8?
    public let clientRTPPort: UInt16?
    public let clientRTCPPort: UInt16?
    public let serverRTPPort: UInt16?
    public let serverRTCPPort: UInt16?
    public let source: String?
    public let ssrc: UInt32?

    /// Parses the FIRST transport-spec if several are comma-separated.
    public static func parse(_ value: String) -> RTSPTransportHeader
}
```

Parsing: take the substring before the first `,`, split on `;`, trim each part.
- Part 0 is the protocol; `isTCPInterleaved` iff it uppercases to something containing
  `/TCP`.
- `interleaved=a-b`, `client_port=a-b`, `server_port=a-b`: parse both sides; if only one
  number is present use it for the first field and `first + 1` for the second.
- `source=<host>` kept verbatim.
- `ssrc=<hex>` parsed with radix 16 (case-insensitive). Unparseable ⇒ nil.
- Unknown keys ignored. Missing keys ⇒ nil, never a crash.

### 4.2 `SDP.swift`

```swift
import Foundation

public struct SDPAttribute: Equatable {
    public let name: String     // "rtpmap", "fmtp", "control", ...
    public let value: String    // "" for a valueless attribute such as "a=recvonly"
}

public struct SDPMediaDescription: Equatable {
    public let mediaType: String        // "video", "audio", ...
    public let port: Int
    public let proto: String            // "RTP/AVP"
    public let formats: [Int]           // payload types from the m= line
    public let attributes: [SDPAttribute]   // media-level a= lines, in order

    public var control: String?         // a=control:
    public func rtpmap(for payloadType: Int) -> String?   // "H264/90000"
    public func fmtp(for payloadType: Int) -> String?     // the raw parameter string
}

public struct SessionDescription: Equatable {
    public let sessionAttributes: [SDPAttribute]
    public let media: [SDPMediaDescription]
    public var sessionControl: String?  // session-level a=control:

    /// Never throws. Unknown/malformed lines are skipped.
    public static func parse(_ text: String) -> SessionDescription
    public static func parse(_ data: Data) -> SessionDescription   // UTF-8, lossy
}
```

Parsing rules: split on `\r\n` or `\n`; each line is `<key>=<value>` with a single-char
key. `m=` opens a new media section and every following `a=`/`b=`/`c=` belongs to it.
`m=video 0 RTP/AVP 96 97` ⇒ `mediaType "video"`, `port 0`, `proto "RTP/AVP"`,
`formats [96, 97]`. `a=name:value` ⇒ `SDPAttribute(name, value)`; `a=name` ⇒ value `""`.
`rtpmap(for:)` matches the leading integer of each `rtpmap` value and returns the rest,
trimmed. `fmtp(for:)` likewise.

```swift
public struct H264TrackDescription: Equatable {
    public let mediaIndex: Int
    public let payloadType: UInt8
    public let clockRate: Int          // from rtpmap; 90000 when absent
    public let packetizationMode: Int  // from fmtp; 0 when absent (RFC 6184 default)
    public let profileLevelId: String? // "42E01E"
    public let sps: [Data]             // raw NAL bytes, no start code, no length prefix
    public let pps: [Data]
    public let control: String?        // the a=control value verbatim
}

public enum SDPH264 {
    /// First `m=video` section whose rtpmap encoding name is "H264" (case-insensitive).
    /// If no rtpmap exists, accept the first `m=video` section whose first format is 96.
    public static func h264Track(in sdp: SessionDescription) -> H264TrackDescription?

    /// "Z0Lg...==,aM48gA==" -> SPS list and PPS list, split by NAL type (7 / 8).
    /// Base64 that fails to decode is skipped. Unknown NAL types are dropped.
    public static func parseSpropParameterSets(_ value: String) -> (sps: [Data], pps: [Data])

    /// One parameter out of "packetization-mode=1;profile-level-id=42E01E;sprop-...=..".
    /// Name match is case-insensitive. Separator is ';'. Value is trimmed; surrounding
    /// double quotes are stripped. Returns nil when absent.
    public static func fmtpValue(_ name: String, in fmtp: String) -> String?
}
```

`parseSpropParameterSets` must tolerate base64 that is missing its `=` padding: pad to a
multiple of 4 with `=` before decoding, and accept both standard and URL-safe alphabets
(map `-`→`+`, `_`→`/`).

```swift
public enum RTSPURL {
    /// RFC 2326 aggregate-control resolution.
    ///   control nil / "" / "*"        -> base unchanged
    ///   control starts "rtsp://" or "rtsps://" (case-insensitive) -> control
    ///   control starts "/"            -> base's scheme + authority + control
    ///   otherwise                     -> base + ("/" unless base already ends with "/")
    ///                                    + control
    public static func resolve(control: String?, base: String) -> String

    /// The base URL for control resolution: Content-Base, else Content-Location,
    /// else the URI the request was sent to. Whitespace-trimmed.
    public static func effectiveBase(requestURI: String, response: RTSPResponse) -> String
}
```

The caller resolves in two steps: `sessionBase = resolve(sdp.sessionControl, base:
effectiveBase)`, then `trackURI = resolve(track.control, base: sessionBase)`.

### 4.3 `RTPPacket.swift`

```swift
import Foundation

public struct RTPPacket: Equatable {
    public let hasMarker: Bool
    public let payloadType: UInt8
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    /// CSRC list and header extension skipped, trailing padding removed.
    public let payload: Data

    public static func parse(_ bytes: [UInt8]) -> RTPPacket?
    public static func parse(_ data: Data) -> RTPPacket?
}
```

**Parse rules (frozen):**

1. Need ≥ 12 bytes, else nil.
2. `version = bytes[0] >> 6` must equal 2, else nil.
3. `padding = bytes[0] & 0x20 != 0`, `extensionBit = bytes[0] & 0x10 != 0`,
   `csrcCount = bytes[0] & 0x0F`.
4. `hasMarker = bytes[1] & 0x80 != 0`, `payloadType = bytes[1] & 0x7F`.
5. `sequenceNumber`, `timestamp`, `ssrc` are **big-endian** at offsets 2, 4, 8.
6. `headerLength = 12 + 4 * csrcCount`; need ≥ that, else nil.
7. If `extensionBit`: need `headerLength + 4`; `extWords = BE u16 at headerLength + 2`;
   `headerLength += 4 + 4 * extWords`; need ≥ that, else nil.
8. If `padding`: `padLen = last byte`; require `1 ≤ padLen ≤ count - headerLength`, else
   nil; drop the trailing `padLen` bytes.
9. Payload may legally be empty; return a packet with `payload == Data()`.

```swift
public enum RTPSeq {
    /// Signed modulo-2^16 distance a - b, in -32768 ..< 32768.
    public static func delta(_ a: UInt16, _ b: UInt16) -> Int   // Int(Int16(bitPattern: a &- b))
    public static func isNewer(_ a: UInt16, than b: UInt16) -> Bool  // delta(a, b) > 0
}

public struct RTPReorderBuffer {
    public struct Stats: Equatable {
        public var received = 0
        public var lost = 0
        public var duplicates = 0
        public var reordered = 0
    }
    public struct Output: Equatable {
        /// Ready-to-depacketize packets, ascending in sequence order. May be empty.
        public let packets: [RTPPacket]
        /// Sequence numbers declared lost immediately before `packets`. 0 normally.
        public let lost: Int
    }

    public let capacity: Int       // max held out-of-order packets, default 32
    public let maxJump: Int        // forward gap that forces a drain, default 1024
    public private(set) var stats: Stats
    public private(set) var expected: UInt16?

    public init(capacity: Int = 32, maxJump: Int = 1024)
    public mutating func push(_ packet: RTPPacket) -> Output
    public mutating func flush() -> Output
    public mutating func reset()
}
```

**`push` algorithm (frozen — vectors pin this exactly):**

1. `stats.received += 1`.
2. If an SSRC has been latched and `packet.ssrc` differs: `reset()`, then continue at
   step 3 (held packets are discarded, `stats.lost` unchanged).
3. If `expected == nil`: latch the SSRC, `expected = seq &+ 1`, return `([packet], 0)`.
4. `d = RTPSeq.delta(packet.sequenceNumber, expected!)`.
   - `d == 0`: deliver it, `expected = seq &+ 1`, then repeatedly pull `held[expected]`
     while present, appending and advancing. Return `(delivered, 0)`.
   - `d < 0`: `stats.duplicates += 1`; return `([], 0)`.
   - `d > 0` and `held[seq] != nil`: `stats.duplicates += 1`; return `([], 0)`.
   - `d > 0`: `held[seq] = packet`, `stats.reordered += 1`. Then, if
     `held.count > capacity || d >= maxJump`, force a drain:
     take the held packet with the smallest positive `delta(_, expected)`,
     `lost = delta(thatSeq, expected)`, `stats.lost += lost`, deliver it, set
     `expected = thatSeq &+ 1`, then drain contiguously as in the `d == 0` case.
     Return `(delivered, lost)`. Otherwise return `([], 0)`.

**`flush`:** deliver every held packet in ascending order, summing the gaps between them
into `lost` (and into `stats.lost`), set `expected` to the last delivered seq `&+ 1`, clear
the held map, return `(delivered, lost)`.

**`reset`:** clears held packets, `expected`, and the latched SSRC. `stats` is preserved.

### 4.4 `H264Depacketizer.swift`

```swift
import Foundation

public enum H264NAL {
    public static let startCode4: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    public static func type(of nal: Data) -> UInt8      // nal.first! & 0x1F; 0 when empty
    public static func isParameterSet(_ nal: Data) -> Bool   // type 7 or 8
    public static func isIDR(_ nal: Data) -> Bool            // type 5

    /// AVCC: each NAL prefixed by its 4-byte BIG-ENDIAN length, concatenated.
    public static func avccPrefixed(_ nals: [Data]) -> Data

    /// Split an Annex-B buffer on 3- or 4-byte start codes. Empty NALs are dropped.
    public static func annexBToNALs(_ data: Data) -> [Data]
}

public enum H264RTPPayload {
    public struct FUA: Equatable {
        public let start: Bool
        public let end: Bool
        public let nalType: UInt8       // the ORIGINAL NAL type, 1..23
        public let nri: UInt8           // 0..3, taken from the FU indicator
        public let fragment: Data
        /// The NAL header byte to prepend when reassembling: (nri << 5) | nalType
        public var reconstructedHeader: UInt8 { (nri << 5) | nalType }
    }

    public enum Kind: Equatable {
        case single(Data)          // types 1...23: the whole payload IS the NAL
        case stapA([Data])         // type 24
        case fuA(FUA)              // type 28
        case unsupported(UInt8)    // 0, 25, 26, 27, 29, 30, 31
    }

    /// nil when the payload is empty or structurally truncated.
    public static func classify(_ payload: Data) -> Kind?

    /// STAP-A body after the 1-byte header: repeated [u16 BE size][size bytes].
    /// nil when any record is truncated or a size is 0.
    public static func splitSTAPA(_ payload: Data) -> [Data]?
}
```

```swift
public struct H264ParameterSets: Equatable {
    public var sps: [Data]
    public var pps: [Data]
    public var isComplete: Bool { !sps.isEmpty && !pps.isEmpty }
    public init(sps: [Data] = [], pps: [Data] = [])
}

public struct H264AccessUnit: Equatable {
    /// Length-prefixed (AVCC, 4-byte BE) VCL/SEI NALs. Parameter sets are NOT included.
    public let avcc: Data
    public let rtpTimestamp: UInt32
    public let isKeyframe: Bool     // contains a type-5 IDR NAL
    public let isCorrupt: Bool      // packet loss was detected while assembling it
}

public struct H264Depacketizer {
    public enum Event: Equatable {
        case accessUnit(H264AccessUnit)
        /// Emitted whenever the stored SPS/PPS set changes (from in-band 7/8 NALs).
        case parameterSets(H264ParameterSets)
        case dropped(reason: String)
    }

    public private(set) var parameterSets: H264ParameterSets

    public init(initial: H264ParameterSets = H264ParameterSets())

    /// Feed ONE in-order packet. `lostBefore` is `RTPReorderBuffer.Output.lost`.
    public mutating func push(_ packet: RTPPacket, lostBefore: Int = 0) -> [Event]
    /// Emit any pending access unit. Call on stop.
    public mutating func flush() -> [Event]
    /// Drop the pending AU and FU-A state. Keeps `parameterSets`.
    public mutating func reset()
}
```

**`push` algorithm (frozen):**

1. If `lostBefore > 0`: discard any in-progress FU-A buffer, mark the open access unit
   `corrupt`, and emit `.dropped(reason: "lost \(lostBefore) RTP packets")`.
2. If an AU is open and `packet.timestamp != openTimestamp`, close and emit the open AU
   **first**, then begin a new one at the new timestamp.
3. Classify the payload:
   - `.single(nal)` → `append(nal)`.
   - `.stapA(nals)` → `append` each in order.
   - `.fuA(f)`:
     - `f.start`: begin a fragment buffer with `[f.reconstructedHeader]` + `f.fragment`.
       If a buffer was already open, drop it and emit `.dropped(reason: "FU-A restart")`.
     - `!f.start`: if no buffer is open, drop the fragment and emit
       `.dropped(reason: "FU-A without start")`. Otherwise append `f.fragment`.
     - `f.end`: `append(completedBuffer)` and clear the buffer.
   - `.unsupported(t)` → emit `.dropped(reason: "unsupported NAL \(t)")`.
   - `classify` returned nil → emit `.dropped(reason: "malformed RTP payload")`.
4. `append(nal)`:
   - type 7 → store as the only SPS if it differs from `parameterSets.sps.first`;
     type 8 → same for PPS. On any change, emit `.parameterSets(parameterSets)`.
     **Parameter sets never go into the AU.**
   - types 9 (AUD) and 12 (filler) → silently dropped.
   - everything else → appended to the open AU's NAL list; type 5 sets `isKeyframe`.
   - If no AU is open, open one at `packet.timestamp`.
5. After processing, if `packet.hasMarker` and the open AU has ≥ 1 NAL: close and emit it.

Closing an AU produces `H264AccessUnit(avcc: H264NAL.avccPrefixed(nals),
rtpTimestamp: openTimestamp, isKeyframe: sawIDR, isCorrupt: sawLoss)` and resets the
open-AU state. An AU with zero NALs is never emitted.

Both AU-boundary triggers (timestamp change, marker bit) must be implemented; whichever
fires first wins. The plotter is expected to set the marker bit, which is the low-latency
path.

---

## 5. `Sources/RTSP/` — the platform layer

### 5.1 `RTSPClient.swift`

```swift
import Foundation
import Network

public enum RTSPTransportMode: Equatable {
    case udp
    case tcpInterleaved
}

public struct RTSPMediaSetup {
    public let track: H264TrackDescription
    public let trackURI: String
    public let aggregateURI: String        // the URI PLAY/TEARDOWN are sent to
    public let mode: RTSPTransportMode
    public let serverRTPPort: UInt16?      // UDP only
    public let serverRTCPPort: UInt16?     // UDP only
    public let rtpChannel: UInt8           // interleaved only; 0 by convention
    public let rtcpChannel: UInt8          // interleaved only; 1 by convention
    public let sessionId: String
    public let sessionTimeout: TimeInterval    // seconds; 60 when the server omits it
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

public final class RTSPClient {
    public init(url: String,
                mode: RTSPTransportMode,
                clientRTPPort: UInt16?,        // required for .udp, ignored for .tcpInterleaved
                queue: DispatchQueue)
    public weak var delegate: RTSPClientDelegate?
    public func start()
    /// Best-effort TEARDOWN then cancel. Idempotent, safe from any thread.
    public func stop()
}
```

**Behaviour (frozen):**

- One serial `DispatchQueue` owns all state. Every delegate call happens on it.
- `NWConnection` to `(host, port)` from the URL. Port defaults to 554. `NWProtocolTCP.Options`
  with `noDelay = true`. `params.includePeerToPeer = false` (matches `HelmSession`).
- The receive buffer is `[UInt8]` with a **read index**, compacted (`removeFirst(readIndex)`)
  only when `readIndex > 65536`. Do not `removeFirst` per item — interleaved TCP can push
  megabytes per second and repeated O(n) shifts will stall the decoder.
- Drain loop: `while let (item, n) = try RTSPWireDecoder.decode(buf, from: readIndex)`.
  - `.interleaved` → `didReceiveInterleaved`.
  - `.request` → reply `RTSP/1.0 200 OK\r\nCSeq: <n>\r\n\r\n` and ignore. Never hang.
  - `.response` → match by `CSeq` to the outstanding request and advance the state machine.
    An unmatched CSeq is logged and ignored.
- A `RTSPParseError` thrown by the decoder ⇒ `.malformedResponse`, then fail.
- State machine: `connect → OPTIONS → DESCRIBE → SETUP → PLAY → playing`.
  - `OPTIONS`: a non-200 is **not** fatal (some servers dislike it) — log and continue to
    DESCRIBE. Record whether `Public:` lists `GET_PARAMETER`.
  - `DESCRIBE`: non-200 ⇒ `.status`. `401` ⇒ `.unauthorized`. Parse the SDP; no H.264
    track ⇒ `.noH264Track`.
  - `SETUP`: `461` or `457` ⇒ `.transportRejected(code:)`. Other non-200 ⇒ `.status`.
    Missing `Session:` ⇒ `.malformedResponse("SETUP without Session")`.
  - `PLAY`: non-200 ⇒ `.status`. On 200 build `RTSPMediaSetup` and call `didPlay`.
- **Timeouts.** 6 s to reach `.ready`; 5 s per request. On expiry ⇒ `.timeout(step:)`,
  where `step` is `"connect"`, `"OPTIONS"`, `"DESCRIBE"`, `"SETUP"` or `"PLAY"`.
- **Keepalive.** After PLAY, every `min(max(sessionTimeout / 2, 5), 25)` seconds send
  `GET_PARAMETER` if the server advertised it, otherwise `OPTIONS`. Both carry `Session:`.
  A non-200 keepalive response is logged, not fatal. A keepalive that gets no response
  within 10 s ⇒ `.timeout(step: "keepalive")`.
- **`stop()`** sends `TEARDOWN`, waits at most 200 ms, then cancels the connection. It must
  not call `didFailWith`; after `stop()` no delegate call may fire.
- **Aggregate URI.** PLAY / GET_PARAMETER / TEARDOWN go to
  `RTSPURL.effectiveBase(requestURI:response:)` of the DESCRIBE response (i.e. the
  `Content-Base`), **not** the track URI. SETUP goes to the track URI.

### 5.2 `RTPUDPTransport.swift`

```swift
import Foundation
import Network

public final class RTPUDPTransport {
    public struct Ports: Equatable {
        public let rtp: UInt16      // always even
        public let rtcp: UInt16     // always rtp + 1
    }

    /// Binds an even RTP port and rtp+1 for RTCP. Tries `attempts` random even bases in
    /// 50000...59998. Returns nil if every attempt fails to bind.
    public init?(queue: DispatchQueue, attempts: Int = 8)

    public let ports: Ports
    /// One datagram, on the transport's queue.
    public var onRTP: ((Data) -> Void)?
    public var onLog: ((String) -> Void)?

    public func start()
    /// Idempotent. Cancels both listeners and every accepted connection.
    public func stop()
}
```

**Implementation notes (frozen):**

- Two `NWListener`s: one on `ports.rtp`, one on `ports.rtcp`, built from
  `NWParameters.udp` with `allowLocalEndpointReuse = true` and
  `includePeerToPeer = false`.
- A UDP `NWListener` creates one `NWConnection` per remote endpoint. **Retain every
  accepted connection in an array** — dropping the reference kills the flow. Start each on
  the transport queue and run a `receiveMessage` loop that re-arms itself until the
  connection reports an error or `isComplete`.
- The RTCP listener's datagrams are read and discarded. v1 sends no Receiver Reports: the
  plotter is on the same LAN (no NAT to punch) and RTSP-level keepalive already holds the
  session open. `ffplay` works either way.
- `init?` returning nil is a normal outcome; `RTSPVideoSession` falls straight through to
  interleaved TCP and logs `"udp bind failed -> TCP"`.
- Log the bound pair once: `"udp ports 51000/51001"`.

### 5.3 `H264VideoView.swift`

```swift
import UIKit
import AVFoundation
import CoreMedia

open class H264VideoView: UIView {
    public override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    /// Cached at init so it can be touched from the video queue.
    public let displayLayer: AVSampleBufferDisplayLayer

    /// Decoded picture size from the SPS. .zero until the first format description.
    public private(set) var videoSize: CGSize

    /// All three are delivered on the MAIN queue.
    public var onVideoSizeChanged: ((CGSize) -> Void)?
    public var onFirstFrame: (() -> Void)?
    public var onDecodeFailure: ((String) -> Void)?

    /// Rebuild the CMVideoFormatDescription. No-op (returns false) when the parameter
    /// sets are byte-identical to the current ones. Returns false on failure too.
    /// Safe to call from the video queue.
    @discardableResult
    public func setParameterSets(sps: [Data], pps: [Data]) -> Bool

    /// Enqueue one AVCC access unit for immediate display. Returns false when there is no
    /// format description yet, or the layer is in a failed state (caller then drops until
    /// the next keyframe). Safe to call from the video queue.
    @discardableResult
    public func enqueue(accessUnit: Data, isKeyframe: Bool, rtpTimestamp: UInt32) -> Bool

    /// Flush queued frames (background/foreground transitions, decode failure).
    public func flushDisplay()
    /// Flush AND drop the format description, so the next SPS/PPS rebuilds it.
    public func reset()
}
```

**Implementation notes (frozen):**

- Layer setup in `commonInit`: `videoGravity = .resizeAspect`,
  `backgroundColor = UIColor.black.cgColor`, and `self.backgroundColor = .black`.
- Format description:
  `CMVideoFormatDescriptionCreateFromH264ParameterSets` with **all** SPS then **all** PPS,
  `nalUnitHeaderLength: 4`. Read `CMVideoFormatDescriptionGetDimensions` into `videoSize`
  and fire `onVideoSizeChanged` on main.
- Sample buffer:
  1. `CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
     blockLength: n, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
     offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &bb)`
  2. `CMBlockBufferReplaceDataBytes` with the AVCC bytes.
  3. `CMSampleBufferCreateReady` with one sample, `sampleSizeArray: [n]`, and
     `CMSampleTimingInfo(duration: .invalid,
                         presentationTimeStamp: CMTime(value: Int64(rtpTimestamp), timescale: 90000),
                         decodeTimeStamp: .invalid)`.
     The PTS is for log/debug only — display order is forced below.
- Attachments on the single sample:
  `kCMSampleAttachmentKey_DisplayImmediately = kCFBooleanTrue` (this is what gives
  low latency with no control timebase), and
  `kCMSampleAttachmentKey_NotSync = kCFBooleanTrue` when `!isKeyframe`.
- Enqueue:
  ```swift
  if #available(iOS 17.0, *) { displayLayer.sampleBufferRenderer.enqueue(sb) }
  else                       { displayLayer.enqueue(sb) }
  ```
  This keeps Xcode 26 warning-free while still building for iOS 16.
- Error handling: before enqueuing, if `displayLayer.status == .failed` (or, on iOS 17+,
  `requiresFlushToResumeDecoding == true`) call `flushDisplay()`, report
  `onDecodeFailure(...)` on main with `displayLayer.error?.localizedDescription`, and
  return false. Also observe
  `.AVSampleBufferDisplayLayerFailedToDecode` and forward its
  `AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey` through `onDecodeFailure`.
- `onFirstFrame` fires exactly once, on main, after the first successful enqueue.
- Everything that touches UIView/CALayer geometry stays on main; only `enqueue`, `flush`
  and `status` reads happen on the video queue (all documented thread-safe on
  `AVSampleBufferDisplayLayer`).

### 5.4 `RTSPVideoSession.swift`

The glue. Owns the client, the UDP transport, the reorder buffer and the depacketizer, and
turns them into `MirrorPlaybackState` plus a stream of things to display.

```swift
import Foundation

public final class RTSPVideoSession {
    /// `preferTCP == false` means "UDP first, automatic one-shot fallback to interleaved
    /// TCP". `true` means "go straight to interleaved TCP".
    public init(url: String, preferTCP: Bool)

    /// Delivered on MAIN.
    public var onState: ((MirrorPlaybackState) -> Void)?
    /// Delivered on the session's serial video queue.
    public var onParameterSets: ((H264ParameterSets) -> Void)?
    /// Delivered on the session's serial video queue.
    public var onAccessUnit: ((H264AccessUnit) -> Void)?

    public func start()
    /// Idempotent; after it returns no callback fires.
    public func stop()
}
```

**Timings (frozen constants, all `private static let`):**

| name | value | meaning |
|---|---|---|
| `rtpArrivalTimeout` | 3.0 s | after PLAY, no RTP at all ⇒ transport fallback or failure |
| `stallTimeout` | 3.0 s | after playing, no RTP ⇒ `.stalled` |
| `deadTimeout` | 10.0 s | after `.stalled` with no recovery ⇒ `.ended` |

**Flow:**

1. `start()` ⇒ `.opening`. If `preferTCP == false`, construct `RTPUDPTransport`; if that
   returns nil, log and switch to `.tcpInterleaved`.
2. Run `RTSPClient`. Log every line via `MirrorDiagnostics.shared.log(...)`.
3. On `didPlay(setup)`:
   - seed the depacketizer with the SDP's SPS/PPS when present and immediately fire
     `onParameterSets`;
   - emit `.buffering`;
   - arm `rtpArrivalTimeout`.
4. RTP arrives (from `onRTP` in UDP mode, or `didReceiveInterleaved` channel
   `setup.rtpChannel` in TCP mode). For each datagram/frame, on the video queue:
   `RTPPacket.parse` → `reorder.push` → for every delivered packet
   `depacketizer.push(pkt, lostBefore:)`.
   - `.parameterSets` ⇒ `onParameterSets`.
   - `.accessUnit` ⇒ keyframe gating (below) then `onAccessUnit`; the first one that is
     actually forwarded flips the state to `.playing`.
   - `.dropped` ⇒ log at most 1 line per second (rate-limit; loss is bursty).
5. **Keyframe gating.** A `needsKeyframe` flag starts `true` and is set `true` again on any
   loss, on decode failure, and on foreground re-entry. While it is set, non-keyframe and
   `isCorrupt` access units are dropped. An `isKeyframe && !isCorrupt` AU clears it.
   This is what stops the green-smear failure mode.
6. **Transport fallback (one shot only).** If `preferTCP == false` and either
   - SETUP returned `.transportRejected`, or
   - `rtpArrivalTimeout` fired with zero RTP packets received,
   then: log `"no RTP over UDP -> retrying interleaved TCP"`, tear the client and the UDP
   transport down, reset the reorder buffer and depacketizer, and start a **fresh**
   `RTSPClient` in `.tcpInterleaved` mode against the same URL. Do this at most once per
   `start()`. A failure after the fallback is a real `.failed`.
7. `.stalled` after `stallTimeout` without RTP once playing; back to `.playing` on the next
   forwarded AU; `.ended` after `deadTimeout` in `.stalled`.
8. `didFailWith` ⇒ log the error, then `.failed` (unless the fallback in 6 applies).
   `rtspClientDidEnd` ⇒ `.ended` if we ever played, `.failed` otherwise.
9. **App lifecycle.** Observe `UIApplication.didEnterBackgroundNotification` ⇒ `stop()`.
   Observe `willEnterForegroundNotification` ⇒ `start()` again from scratch. Network
   sockets do not survive suspension; a fresh session is the only reliable recovery.

`ContentView`'s outer `MirrorAttempt` ladder still exists as the last safety net, so the
session must never take longer than `MirrorScreen.attemptTimeout` (8 s) to reach either
`.playing` or `.failed`. The budget: ~1 s handshake + 3 s RTP wait + ~1 s TCP retry
handshake + 3 s RTP wait = 8 s worst case. Do not raise these constants without also
raising `attemptTimeout`.

---

## 6. Interaction with the existing UI (all preserved)

### 6.1 `MirrorPlaybackState` — unchanged

`.opening | .buffering | .playing | .stalled | .ended | .failed`, with `isPlaying` and
`message`. Do not add cases: `ContentView` switches on `== .failed`, `== .ended` and
`.isPlaying`.

### 6.2 `MirrorDiagnostics` — API unchanged, ring buffer enlarged

`shared`, `log(_:)`, `reset()`, `@Published text` all stay. The only change: the ring grows
from **12 to 40 lines**, because a full RTSP exchange is ~25 lines and truncating it
defeats the purpose. `NSLog("[HelmMirror] %@", message)` per line stays.

Optional but recommended: coalesce the `DispatchQueue.main.async` publish to at most 10 Hz
so a burst of RTSP lines does not thrash SwiftUI.

### 6.3 `MirrorAttempt` — signature and behaviour unchanged

`ladder(for:)` still returns `[UDP url1, UDP url2, TCP url1, TCP url2]`. What changes is
only the *meaning* of `useTCP`, which is now `preferTCP` (§5.4): `false` = "UDP with
automatic TCP fallback", `true` = "interleaved TCP only". In practice attempt 1 now
succeeds and the ladder is never walked — but it stays as the net.

### 6.4 `MirrorPlayerView` — public API frozen, verbatim

```swift
public struct MirrorPlayerView: UIViewRepresentable {
    public let rtspURL: String
    public let useTCP: Bool
    public let videoAspect: CGFloat
    public let onTouch: ([HelmTouchPoint]) -> Void
    public let onState: (MirrorPlaybackState) -> Void

    public init(rtspURL: String,
                useTCP: Bool = false,
                videoAspect: CGFloat = 1280.0 / 720.0,
                onTouch: @escaping ([HelmTouchPoint]) -> Void,
                onState: @escaping (MirrorPlaybackState) -> Void = { _ in })

    public func makeUIView(context: Context) -> UIView
    public func updateUIView(_ uiView: UIView, context: Context)
    public static func dismantleUIView(_ uiView: UIView, coordinator: ())
}
```

`makeUIView` / `updateUIView` / `dismantleUIView` keep their exact current bodies, still
calling `view.play(urlString:useTCP:)` and `view.teardown()`.

### 6.5 `ContentView.swift` — not modified

It must keep compiling untouched. Anything that would require editing it is a spec
violation; raise it rather than editing.

---

## 7. `MirrorVideoView` — what is frozen and what is replaced

```swift
final class MirrorVideoView: H264VideoView { ... }
```

### 7.1 FROZEN — copy these members across byte for byte

Copy from the current `Sources/MirrorPlayerView.swift` with **zero edits**:

- the stored properties `videoAspect`, `onTouch`, `trackIds`, `usedIds`
- `touchesBegan/Moved/Ended/Cancelled(_:with:)`
- `private func emit(_ touches: Set<UITouch>, event: UIEvent?, down: Bool)` — including the
  `coalescedTouches` expansion and the `contentRect()` guard
- `trackId(for:)`, `nextFreeId()`, `releaseIds(for:)`
- `contentRect()` and `clamp01(_:)`

The comments on those members are part of the frozen text; keep them. The normalization is
`nx = (p.x - rect.minX) / rect.width`, `ny = (p.y - rect.minY) / rect.height`, clamped to
0…1, top-left origin. `videoAspect` continues to come from the representable and is
**never** overwritten from the SPS-derived `videoSize` — the SwiftUI `.aspectRatio(...)`
modifier defines the layout, so overriding it would silently break the touch mapping. Log
the SPS size instead.

`commonInit` keeps `backgroundColor = .black`, `isMultipleTouchEnabled = true`,
`isUserInteractionEnabled = true`.

### 7.2 REPLACED

| removed | replaced by |
|---|---|
| `import MobileVLCKit`, `VLCMediaPlayer`, `VLCMediaPlayerDelegate` | `RTSPVideoSession` |
| `enableVLCLogging()`, `name(for:)`, `report(for:)`, `hasRealVideo` | session state callbacks |
| `videoWatch` polling timer | `RTSPVideoSession`'s stall/dead timers |
| `layoutSubviews()` re-attach hack | nothing — `AVSampleBufferDisplayLayer` needs none |
| `sawVideoOut` | `everPlayed` inside the session |

### 7.3 KEPT, reimplemented

```swift
/// Load `urlString` and start playback. Idempotent for an unchanged attempt.
func play(urlString: String, useTCP: Bool = false)
/// Stop playback and release resources. Called from `dismantleUIView`.
func teardown()
```

`play` keeps the `"\(useTCP ? "tcp" : "udp")|\(urlString)"` dedupe key and the
`MirrorDiagnostics.shared.log("try \(useTCP ? "TCP" : "UDP") \(urlString)")` first line, so
the on-screen log still opens the same way. It then builds an `RTSPVideoSession` and wires:

```swift
session.onParameterSets = { [weak self] ps in
    self?.setParameterSets(sps: ps.sps, pps: ps.pps)      // video queue, layer-safe
}
session.onAccessUnit = { [weak self] au in
    self?.enqueue(accessUnit: au.avcc, isKeyframe: au.isKeyframe, rtpTimestamp: au.rtpTimestamp)
}
session.onState = { [weak self] state in self?.emit(state) }   // already on main
```

`emit(_ mapped: MirrorPlaybackState)` keeps its current de-duplicating shape (only report
on change, hop to main).

`teardown()` calls `session.stop()`, nils the session, calls `reset()` on the view, and
clears `currentURLString`.

---

## 8. `Verify/main.swift` — new byte vectors (Foundation-only)

Append these sections after the existing ones. The harness (`section`, `check`,
`expectTrue`, `hex`) is unchanged. **All of these must pass with `swift run helmverify`
on a Mac with no Xcode.** Existing count: 72. Target after this work: ~142.

### 8.1 `section("RTSP requests")`

```
OPTIONS serialization ==
"OPTIONS rtsp://172.16.6.155:554/helm_1280x720.h264 RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: HelmMirror/1.0\r\n\r\n"

DESCRIBE serialization ==
"DESCRIBE rtsp://h/s RTSP/1.0\r\nCSeq: 2\r\nAccept: application/sdp\r\nUser-Agent: HelmMirror/1.0\r\n\r\n"

setupUDP(uri:"rtsp://h/s/track1", cseq:3, clientRTPPort:51000) ==
"SETUP rtsp://h/s/track1 RTSP/1.0\r\nCSeq: 3\r\nTransport: RTP/AVP;unicast;client_port=51000-51001\r\nUser-Agent: HelmMirror/1.0\r\n\r\n"

setupTCP(uri:"rtsp://h/s/track1", cseq:3, rtpChannel:0, rtcpChannel:1) ==
"SETUP rtsp://h/s/track1 RTSP/1.0\r\nCSeq: 3\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nUser-Agent: HelmMirror/1.0\r\n\r\n"

play(uri:"rtsp://h/s/", cseq:4, session:"8FE3A1B2") ==
"PLAY rtsp://h/s/ RTSP/1.0\r\nCSeq: 4\r\nSession: 8FE3A1B2\r\nRange: npt=0.000-\r\nUser-Agent: HelmMirror/1.0\r\n\r\n"
```

### 8.2 `section("RTSP responses")`

Input A (one string, `\r\n` line endings):
```
RTSP/1.0 200 OK
CSeq: 2
Content-Base: rtsp://172.16.6.155:554/helm_1280x720.h264/
Content-Type: application/sdp
Content-Length: 5

hello
```
- `statusCode == 200`, `reasonPhrase == "OK"`, `cseq == 2`
- `header("content-base") == "rtsp://172.16.6.155:554/helm_1280x720.h264/"`
- `header("Content-Type") == "application/sdp"` (lookup is case-insensitive)
- `String(data: body) == "hello"`, `consumed == A.utf8.count`
- truncating A by one byte ⇒ `decode` returns nil
- head-only (no `Content-Length`) `"RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n"` ⇒ `consumed == 28`

Session header:
- `"RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 8FE3A1B2;timeout=60\r\n\r\n"` ⇒
  `sessionId == "8FE3A1B2"`, `sessionTimeout == 60`
- `"Session: ABC"` ⇒ `sessionId == "ABC"`, `sessionTimeout == nil`

Errors / other:
- `"RTSP/1.0 461 Unsupported transport\r\nCSeq: 3\r\n\r\n"` ⇒ `statusCode == 461`,
  `reasonPhrase == "Unsupported transport"`, `isSuccess == false`
- `"HTTP/1.1 200 OK\r\n\r\n"` ⇒ parsed as a **server request** (first token is not `RTSP/…`
  and there are 3 tokens) — assert `.request(method: "HTTP/1.1")` is NOT produced; instead
  this must throw `.malformedRequestLine`. (Guard rail: the third token must be `RTSP/1.0`.)
- `"OPTIONS rtsp://x RTSP/1.0\r\nCSeq: 7\r\n\r\n"` ⇒ `.request(method "OPTIONS", cseq 7)`
- LF-only head `"RTSP/1.0 200 OK\nCSeq: 1\n\n"` parses with `consumed == 25`

### 8.3 `section("RTSP interleaved framing")`

- `[0x24, 0x00, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF]` ⇒
  `.interleaved(channel: 0, payload: "deadbeef")`, `consumed == 8`
- `[0x24, 0x01, 0x00, 0x02, 0xAA]` ⇒ nil (incomplete)
- `[0x24, 0x00, 0x00, 0x00]` ⇒ `.interleaved(channel: 0, payload: "")`, `consumed == 4`
- mixed: an 8-byte `$` frame followed by `"RTSP/1.0 200 OK\r\nCSeq: 9\r\n\r\n"` decodes to
  two items with the right `consumed` values when driven with `from:`

### 8.4 `section("RTSP Transport header")`

- `"RTP/AVP;unicast;client_port=51000-51001;server_port=6970-6971;ssrc=1A2B3C4D"` ⇒
  `isTCPInterleaved false`, `clientRTPPort 51000`, `serverRTPPort 6970`,
  `serverRTCPPort 6971`, `ssrc 0x1A2B3C4D`
- `"RTP/AVP/TCP;unicast;interleaved=0-1"` ⇒ `isTCPInterleaved true`, `rtpChannel 0`,
  `rtcpChannel 1`, `serverRTPPort nil`
- `"RTP/AVP;unicast;source=172.16.6.155;client_port=9244"` ⇒ `source "172.16.6.155"`,
  `clientRTPPort 9244`, `clientRTCPPort 9245`
- garbage `"nonsense"` ⇒ every optional nil, no crash

### 8.5 `section("SDP")`

Fixture (exactly this, LF line endings):
```
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
```
- `media.count == 1`, `mediaType == "video"`, `port == 0`, `proto == "RTP/AVP"`,
  `formats == [96]`
- `sessionControl == "*"`, `media[0].control == "track1"`
- `rtpmap(for: 96) == "H264/90000"`
- `SDPH264.fmtpValue("packetization-mode", in: fmtp) == "1"`
- `SDPH264.fmtpValue("PROFILE-LEVEL-ID", in: fmtp) == "42E01E"` (case-insensitive)
- `SDPH264.fmtpValue("nope", in: fmtp) == nil`
- `h264Track(in:)` ⇒ `payloadType 96`, `clockRate 90000`, `packetizationMode 1`,
  `sps.count 1`, `pps.count 1`, `control "track1"`

Parameter-set bytes (verified base64):
```
hex(sps[0]) == "6742e01eda014016e840000003004000000ca1e30654"   (22 bytes, NAL type 7)
hex(pps[0]) == "68ce3c80"                                        (4 bytes,  NAL type 8)
```
Also check unpadded base64 survives: `parseSpropParameterSets("aM48gA")` ⇒
`pps == ["68ce3c80"]`.

### 8.6 `section("RTSP control URL joining")`

```
resolve("track1",  base: "rtsp://h:554/s.h264")   == "rtsp://h:554/s.h264/track1"
resolve("track1",  base: "rtsp://h:554/s.h264/")  == "rtsp://h:554/s.h264/track1"
resolve("/track1", base: "rtsp://h:554/s.h264")   == "rtsp://h:554/track1"
resolve("rtsp://other/z", base: "rtsp://h/s")     == "rtsp://other/z"
resolve("*",   base: "rtsp://h/s")                == "rtsp://h/s"
resolve(nil,   base: "rtsp://h/s")                == "rtsp://h/s"
resolve("trackID=0", base: "rtsp://h:554/helm_1280x720.h264")
                                                  == "rtsp://h:554/helm_1280x720.h264/trackID=0"
effectiveBase(requestURI: "rtsp://h/s", response with Content-Base "rtsp://h/s/")  == "rtsp://h/s/"
effectiveBase(requestURI: "rtsp://h/s", response with no such headers)             == "rtsp://h/s"
```

### 8.7 `section("RTP header")`

```
80 60 00 2A 00 01 E2 40 DE AD BE EF 67 42 E0 1E
  -> marker false, pt 96, seq 42, ts 123456, ssrc 0xDEADBEEF, payload "6742e01e"

80 E0 00 2A 00 01 E2 40 DE AD BE EF AA
  -> marker true, pt 96, payload "aa"

A0 60 00 2A 00 01 E2 40 DE AD BE EF AA 00 00 03      (padding bit, padLen 3)
  -> payload "aa"

90 60 00 2A 00 01 E2 40 DE AD BE EF BE DE 00 01 11 22 33 44 AA BB   (ext, 1 word)
  -> payload "aabb"

82 60 00 2A 00 01 E2 40 DE AD BE EF 11 11 11 11 22 22 22 22 AA      (cc=2)
  -> payload "aa"

40 60 00 2A 00 01 E2 40 DE AD BE EF AA   (version 1) -> nil
first 11 bytes of any of the above                    -> nil
A0 60 00 2A 00 01 E2 40 DE AD BE EF FF   (padLen 255 > payload) -> nil
```

`RTPSeq`: `delta(0, 65535) == 1`, `delta(65535, 0) == -1`, `delta(5, 5) == 0`,
`isNewer(0, than: 65535) == true`, `isNewer(65535, than: 0) == false`.

### 8.8 `section("RTP reorder buffer")`

Build packets with a helper `rtp(seq:ts:marker:payload:ssrc:)` that emits the 12-byte
header plus payload and parses it back.

| # | pushes | expected |
|---|---|---|
| 1 | 100, 101, 102 | each returns `([that], 0)` |
| 2 | 100, 102, 101 | `([100],0)`, `([],0)`, `([101,102],0)` |
| 3 | 100, 102, then `flush()` | flush ⇒ `([102], 1)`; `stats.lost == 1` |
| 4 | 100, 101, 100 | third ⇒ `([],0)`; `stats.duplicates == 1` |
| 5 | 65535, 0, 1 | each returns `([that], 0)` — wrap works |
| 6 | capacity 2: 100, 102, 103, 104 | 4th ⇒ `([102,103,104], 1)` |
| 7 | 100 (ssrc A), 200 (ssrc B) | 2nd ⇒ `([200], 0)`, `stats.lost == 0` |

### 8.9 `section("H.264 depacketization")`

`H264RTPPayload.classify`:
```
"419a00"            -> .single("419a00")                       (type 1)
"6742e01e"          -> .single("6742e01e")                     (type 7)
"7c85aabb"          -> .fuA(start true,  end false, nalType 5, nri 3, fragment "aabb")
"7c05cc"            -> .fuA(start false, end false, nalType 5, nri 3, fragment "cc")
"7c45dd"            -> .fuA(start false, end true,  nalType 5, nri 3, fragment "dd")
""                  -> nil
"7c"                -> nil            (FU-A with no FU header)
"5900"              -> .unsupported(25)
```
`reconstructedHeader` for the start fragment above `== 0x65`.

`splitSTAPA` (payload includes the 0x78 STAP-A header):
```
"780016" + "6742e01eda014016e840000003004000000ca1e30654" + "0004" + "68ce3c80"
  -> ["6742e01eda014016e840000003004000000ca1e30654", "68ce3c80"]
"78000467 42"                       -> nil   (truncated record)
"780000" + "..."                    -> nil   (zero-size record)
```

`H264NAL`:
```
avccPrefixed([Data([0x65,0xAA])])                    -> "0000000265aa"
avccPrefixed([Data([0x67]), Data([0x68,0x01])])      -> "0000000167000000026801"
annexBToNALs("00000001" + "67aa" + "000001" + "68bb") -> ["67aa", "68bb"]
type(of: "65aa") == 5 ; isIDR == true ; isParameterSet("6742") == true
```

`H264Depacketizer` end-to-end:

1. **FU-A reassembly.** Push, all `ts = 9000`, seq 1..3, marker only on the third:
   `7c85aabb`, `7c05cc`, `7c45dd`.
   ⇒ exactly one `.accessUnit` with `hex(avcc) == "0000000565aabbccdd"`,
   `isKeyframe == true`, `isCorrupt == false`, `rtpTimestamp == 9000`.
2. **Single NAL + marker.** Push `ts 9000`, marker, payload `419a00`
   ⇒ `.accessUnit` with `hex(avcc) == "00000003419a00"`, `isKeyframe == false`.
3. **Parameter sets are extracted, not embedded.** Push the STAP-A from above with
   `marker == false` ⇒ events contain exactly one `.parameterSets`, **zero** `.accessUnit`,
   and `depacketizer.parameterSets.sps.count == 1 && .pps.count == 1`.
4. **Timestamp boundary.** Push `ts 9000` `419a00` (no marker), then `ts 12000` `419a00`
   ⇒ first push emits nothing; second emits one `.accessUnit` with `rtpTimestamp == 9000`.
   Then `flush()` emits the `ts 12000` AU.
5. **Loss marks corruption.** Push `ts 9000` `7c85aabb`, then push `ts 9000` `7c45dd` with
   `lostBefore: 2` ⇒ a `.dropped` event is emitted, the FU-A buffer is discarded, and no
   access unit containing `aabb` is ever produced.
6. **AUD/filler dropped.** Push `ts 9000`, marker, payload `09f0` (AUD) ⇒ no `.accessUnit`
   (an AU with zero NALs is never emitted).

---

## 9. Risks, and what to do about each

### 9.1 The plotter really does reject interleaved TCP (`461`)

Then the UDP path is the only path, and it must work. It should: `ffplay -rtsp_transport udp`
proves the server streams RTP to a client-chosen UDP port. If SETUP returns 461 for TCP the
session logs `"461 Unsupported transport"` and reports `.failed` for that attempt — the
outer ladder then moves on. Never silently retry TCP in a loop.

### 9.2 `NWListener`-over-UDP does not receive

If `init?` succeeds but zero datagrams arrive within `rtpArrivalTimeout` while the RTSP
side reported `200 OK` to PLAY, the fallback to interleaved TCP fires automatically (§5.4
step 6) and the failure is visible in the log as `"no RTP over UDP -> retrying interleaved
TCP"`. The documented alternative, if this ever proves to be the sticking point, is a plain
BSD `socket()/bind()/recvfrom()` on a `DispatchSourceRead` — same interface, swap the
implementation of `RTPUDPTransport` only.

### 9.3 `AVSampleBufferDisplayLayer` refuses the stream

Symptom: `enqueue` succeeds but nothing renders and `displayLayer.status == .failed`. The
documented hook is a `VTDecompressionSession` path behind the same
`H264VideoView.enqueue(accessUnit:isKeyframe:rtpTimestamp:)` signature, rendering
`CVPixelBuffer`s into an `AVSampleBufferDisplayLayer` or a `CAMetalLayer`. **Do not build
it now.** Build it only if the on-screen log shows access units flowing and the layer
failing.

### 9.4 The plotter sends parameter sets only in band

Already handled: `H264Depacketizer` captures in-band SPS/PPS and emits `.parameterSets`,
and `H264VideoView.enqueue` returns `false` (dropping the AU) until a format description
exists. Combined with keyframe gating this self-heals on the next IDR.

### 9.5 Local Network permission

Already granted — discovery and pairing work. `NSBonjourServices` and
`NSLocalNetworkUsageDescription` in `project.yml` are unchanged. UDP to a LAN peer is
covered by the same grant.

### 9.6 iOS 17 deprecations under the Xcode 26 SDK

`AVSampleBufferDisplayLayer.enqueue(_:)` and `flush()` are deprecated in favour of
`sampleBufferRenderer`. The `#available(iOS 17.0, *)` split in §5.3 keeps the build
warning-free while still deploying to iOS 16.

---

## 10. Implementation order (files are independent once the interfaces above are fixed)

The four `RTSPCore` files have no dependency on each other except that
`H264Depacketizer` uses `RTPPacket`. They can be written in parallel, each verified by its
own `Verify/main.swift` section with no simulator and no Xcode.

1. `RTSPCore/RTSPMessage.swift` + §8.1–8.4 vectors
2. `RTSPCore/SDP.swift` + §8.5–8.6 vectors
3. `RTSPCore/RTPPacket.swift` + §8.7–8.8 vectors
4. `RTSPCore/H264Depacketizer.swift` + §8.9 vectors
5. `Package.swift` edit; `swift run helmverify` green (≈142 vectors)
6. `RTSP/H264VideoView.swift` (independently testable: feed it a canned SPS/PPS + one IDR
   access unit and confirm a picture)
7. `RTSP/RTPUDPTransport.swift`
8. `RTSP/RTSPClient.swift`
9. `RTSP/RTSPVideoSession.swift`
10. `MirrorPlayerView.swift` rewrite (touch code copied verbatim per §7.1)
11. Delete `Podfile`; update `project.yml`, `README.md`, `.github/workflows/ios-build.yml`
12. Build and run on the iPhone 17 Pro Max (`AE53ACEB-A47C-583E-B64C-1CA0C37D269B`)

**Definition of done:** `swift run helmverify` passes; the app builds with no CocoaPods and
no third-party dependency; on the boat the on-screen diagnostic shows the literal RTSP
request/response lines followed by `.playing`, and touches still reach the plotter.

---

## 11. Logging contract (non-negotiable)

The last three bugs were solved by reading the on-screen log, so the log is a deliverable,
not a debugging aid. Every one of these lines must appear, in this order, via
`MirrorDiagnostics.shared.log(...)`:

```
try UDP rtsp://172.16.6.155:554/helm_1280x720.h264
udp ports 51000/51001
tcp connect 172.16.6.155:554
> OPTIONS rtsp://172.16.6.155:554/helm_1280x720.h264 RTSP/1.0 (CSeq 1)
< RTSP/1.0 200 OK  [Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN]
> DESCRIBE (CSeq 2)
< RTSP/1.0 200 OK  Content-Length 512
sdp: video pt=96 H264/90000 pmode=1 sps=22B pps=4B control=track1
> SETUP rtsp://.../track1 (CSeq 3) Transport: RTP/AVP;unicast;client_port=51000-51001
< RTSP/1.0 200 OK  server_port=6970-6971 session=8FE3A1B2 timeout=60
> PLAY (CSeq 4)
< RTSP/1.0 200 OK
rtp: first packet seq=42 ts=123456 pt=96
fmt: 1280x720
video: first frame
```

Rules:
- Requests are logged as `> METHOD uri (CSeq n)` plus the `Transport:` header when present.
  Full request text goes to `NSLog` only.
- Responses are logged as `< <status line>` plus the headers that matter for the next step
  (`Public`, `Content-Base`, `Content-Length`, `Transport`, `Session`, `WWW-Authenticate`).
- Every `RTSPClientError` logs as `err: <description>` before the state change.
- Loss and dropped-fragment logs are rate-limited to 1 per second.
- No log line may exceed ~110 characters; truncate with `…`.
