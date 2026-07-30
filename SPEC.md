# HelmMirror — Frozen Implementation Spec (v1.0)

Universal iOS app that discovers any Garmin chartplotter (MFD) over Wi‑Fi and mirrors +
controls its screen, using Garmin's private ActiveCaptain "Helm" protocol
(reverse‑engineered; verified against a **Garmin GPSMAP 923xsv**; all plaintext, no TLS).

This document is **authoritative and self‑contained**. Implementers build the app‑layer
files strictly to the interfaces here. The byte layouts in §4 and the public API in §6 are
frozen — do not change them. Every byte vector in this spec is reproduced by the passing
Foundation‑only test suite (`Sources/HelmProtocol.swift` + `Tests/HelmWireTests`).

---

## 1. Scope & non‑goals

**In scope (v1):**
- Bonjour discovery of the plotter.
- One‑time HTTP pairing (register identity + set role) with on‑MFD human approval.
- TCP session: handshake, acquire a touch context, receive the RTSP URL, keepalive.
- Live video via MobileVLCKit (RTSP/H.264 over UDP).
- Single‑finger touch (tap + drag) mirrored back to the plotter.

**Non‑goals (v1):**
- Two‑finger pinch/zoom. The plotter's 2‑finger payload is an idiosyncratic 40‑byte
  template (see §4.7); single‑finger control covers normal operation. A hook is left for
  later, but the core encoder emits only the clean multi‑point form.
- Any write/telemetry beyond touch. No NMEA, no waypoint editing beyond what the mirrored
  UI itself does.
- Persisting video, screenshots, or route data.

---

## 2. Architecture & module split

**Principle:** every pure‑byte protocol decision lives in one Foundation‑only file,
`Sources/HelmProtocol.swift`, so it unit‑tests on macOS with `swift test` — no Simulator,
no Network.framework, no UIKit, no VLC. Everything that touches the network or the UI lives
in the app target and depends only on the public API of `HelmProtocol`.

| File | Imports | Responsibility |
|---|---|---|
| `Sources/HelmProtocol.swift` | `Foundation` only | Frame codec, message builders/parser, touch encoder, pairing protobuf + `<tag>`, byte helpers, **all shared model types**. Architect‑owned; frozen. |
| `Sources/GarminDiscovery.swift` | `Foundation`, `Network`, `Combine` | `NWBrowser` over Bonjour; publishes `[DiscoveredPlotter]`; resolves host+ports. |
| `Sources/HelmPairing.swift` | `Foundation` | `URLSession` PUT pairing + set‑role against the plotter's nginx (port 80). |
| `Sources/HelmSession.swift` | `Foundation`, `Network` | `NWConnection` TCP 51200; handshake; frame reassembly; EVENT→RTSP URL; 5 s keepalive; `sendTouch`. |
| `Sources/MirrorPlayerView.swift` | `SwiftUI`, `UIKit`, `MobileVLCKit` | `UIViewRepresentable` wrapping `VLCMediaPlayer`; captures touches → normalized coords → callback. |
| `Sources/ContentView.swift` | `SwiftUI` | UI: discovery list, connect flow, pairing‑approval instructions, mirror. Hosts the view model. |
| `Sources/HelmMirrorApp.swift` | `SwiftUI` | `@main` App entry. |
| `Tests/HelmWireTests/HelmWireTests.swift` | `XCTest`, `@testable HelmProtocol` | Byte‑exact vectors. Architect‑owned; frozen. |

Cross‑file data types (`DiscoveredPlotter`, `ConnectionState`, `HelmInbound`,
`HelmTouchPoint`, `HelmError`) are defined **once**, in `HelmProtocol.swift`, and are
Foundation‑only by construction (no `NWEndpoint` leaks into the shared model — discovery
resolves endpoints down to `host: String` + ports).

---

## 3. Ground‑truth protocol facts (with resolved corrections)

The MFD is its own Wi‑Fi AP; the phone joins it. Default host observed in captures is
`172.16.6.0`, but **always resolve via Bonjour — never hardcode.**

**Bonjour service types advertised by the plotter:**

| Service | Port | TXT keys | Use |
|---|---|---|---|
| `_garmin-helm._tcp` | 51200 | `version` | Helm **session** (TCP). |
| `_garmin-bl-id._tcp` | 80 | `tag`, `hasDisplay`, `version` | **Pairing/identity** HTTP (nginx). |
| `_garmin-mrn-cred._tcp` | — | — | Present on some units; **not needed** for the 923xsv. |
| `_garmin-bl-app._tcp`, `_garmin-mrn-html._tcp`, `_garmin-marine._udp` | — | — | Not used. |

**Resolved corrections vs. the loose brief (these are FROZEN decisions):**

1. **SUBSCRIBE is 16 separate frames, not one.** Verified against the reference client's
   source: the handshake iterates the 16 indices and sends each as its own `0x1648` frame
   with a **4‑byte u32 LE** payload. It is *not* a single frame carrying a 16‑byte blob.
   Indices (in order, duplicates included): `0b 00 01 06 08 0a 03 04 05 09 01 08 00 0a 02 0c`.
2. **Fixed‑point ceiling is 65536** (= `TOUCH_UNITY`), not 65535. `encoded = clamp(round(n*65536), 0, 65536)`; normalized `1.0` → `0x00010000`.
3. **RTSP URL:** the authoritative URL arrives in EVENT `0x1649` subtype 0. The reference
   client hardcodes it, so treat EVENT parsing as the primary path **and** keep the
   deterministic fallback `rtsp://<host>:554/helm_1280x720.h264`.
4. **Keepalive is required.** Ground truth (verified against real hardware) says the client
   must re‑subscribe roughly every **5 s** or the plotter stops streaming (~30 s hard
   timeout). The minimal reference client omits it (it never runs long enough to time out),
   so it is unverified *there* — but we implement it because the real device requires it.
   **Frozen policy:** re‑send the full 16‑frame SUBSCRIBE burst every 5 s. Make the interval
   a single named constant so it can be tuned empirically.
5. **Pairing host = `_garmin-bl-id._tcp` (port 80).** `_garmin-mrn-cred._tcp` is a
   cross‑unit alias not present/needed on the 923xsv; do not depend on it.
6. **Two‑finger pinch is a literal 40‑byte template**, not two clean 16‑byte points; v1 does
   not emit it (see §4.7).

---

## 4. Wire byte layouts + concrete test vectors

All multi‑byte integers are **little‑endian** unless stated. All vectors below are asserted
green by the test suite.

### 4.1 Frame envelope

```
[u16 type LE][u16 magic=0xBEEF LE][u32 length LE][payload  (length bytes)]
```
- Header is 8 bytes; total frame = 8 + length.
- `magic` is always `0xBEEF`. On decode, callers may re‑sync on a bad magic (session‑layer
  concern); the core decoder returns bytes regardless.

### 4.2 Message type IDs

| Name | ID | Dir | Payload |
|---|---|---|---|
| HELLO | `0x083F` | C→P | `u16 LE 0x9531` (2 bytes) |
| TOKEN | `0x0AA9` | C→P | 8 client‑random bytes |
| SUBSCRIBE | `0x1648` | C→P | `u32 LE index` (4 bytes) — **sent once per index** |
| ACQUIRE | `0x1644` | C→P | empty |
| CONTEXT | `0x1645` | P→C | `[u32 LE 1][u32 LE ctx_id]` |
| EVENT | `0x1649` | P→C | `[u32 LE subtype][u32 LE len][data]` |
| TOUCH | `0x164C` | C→P | see §4.6 |

### 4.3 Handshake — exact send order

1. **HELLO** `0x083F`, payload `31 95`.
2. **TOKEN** `0x0AA9`, payload = 8 random bytes (fresh per session).
3. **SUBSCRIBE ×16** `0x1648`, one frame per index in the order
   `0b 00 01 06 08 0a 03 04 05 09 01 08 00 0a 02 0c`, each a 4‑byte u32 LE.
4. **ACQUIRE** `0x1644`, empty.
5. Wait for **CONTEXT** `0x1645` → take the **second** u32 as `ctx_id` (the touch context;
   prefix every TOUCH with it).
6. **EVENT** `0x1649` subtype 0 → RTSP URL string (authoritative). If none within ~1 s, use
   the deterministic fallback.
7. Start **keepalive**: re‑send the full SUBSCRIBE burst every 5 s.

**Vectors:**
```
HELLO                : 3f08efbe020000003195
TOKEN (deadbeef01020304)
                     : a90aefbe08000000deadbeef01020304
SUBSCRIBE idx 0x0b   : 4816efbe040000000b000000
SUBSCRIBE idx 0x00   : 4816efbe0400000000000000
SUBSCRIBE burst      : 16 frames × 12 bytes = 192 bytes; first=idx0x0b, last=idx0x0c
ACQUIRE              : 4416efbe00000000
```

### 4.4 CONTEXT (inbound)

Payload `[u32 LE 1][u32 LE ctx_id]`. Use `ctx_id` = the **second** u32.
Vector: payload `01 00 00 00 05 00 00 00` → `ctx_id = 5`.

### 4.5 EVENT (inbound)

Payload `[u32 LE subtype][u32 LE len][data (len bytes)]`.
- subtype 0 → `data` is the RTSP URL as UTF‑8 (trim trailing NUL/whitespace).
- subtype 1 → inline H.264 + device name (kept raw; not used by v1).

Vector (subtype 0, url `rtsp://172.16.6.0:554/helm_1280x720.h264`):
`[00000000][28000000]["rtsp://…"]` → `.rtspURL("rtsp://172.16.6.0:554/helm_1280x720.h264")`.

### 4.6 TOUCH (outbound) — the clean multi‑point form (v1)

Payload:
```
[u32 LE ctx_id][u32 LE point_count]  then point_count × 16-byte point:
  [u8 track_id][u32 LE x][u32 LE y][u32 LE down][3 × 0x00 pad]
```
- `x`, `y` = 16.16 fixed‑point of the normalized 0..1 coordinate, top‑left origin:
  `encoded = clamp(round(n * 65536), 0, 65536)`.
- `down`: 1 = press/move, 0 = release.
- One point = 16 bytes; payload = 8 + 16·count.

**Vectors** (single finger, `ctx_id = 5`, center `(0.5, 0.5)`):
```
press (down=1)   : 4c16efbe18000000 05000000 01000000 00 00800000 00800000 01000000 000000
                 = 4c16efbe18000000050000000100000000008000000080000001000000000000
release (down=0) : 4c16efbe18000000050000000100000000008000000080000000000000000000
```
Fixed‑point: `fixed16_16(0.0)=0`, `0.25=0x4000`, `0.5=0x8000`, `1.0=0x10000`, clamp `>1→0x10000`, `<0→0`.

### 4.7 PINCH (outbound) — NOT emitted by v1 (reference only)

The plotter's two‑finger payload is an idiosyncratic 40‑byte template — the `down` flag is a
single byte and finger‑2's `track_id` is inline `0x01`, so it does **not** decompose into two
uniform 16‑byte points:
```
[ctx:4][count=2:4] 00 [x0:4][y0:4][down0:1] 01 00 00 00 [x1:4][y1:4][down1:1] 00×9
```
If pinch is added later, replicate this byte‑for‑byte; do not synthesize it from the clean
point form.

### 4.8 Pairing protobuf — `MobileDeviceIdentity`

Hand‑encoded (no protobuf runtime). Message `CSM.Proto.Common.MobileDeviceIdentity`:

| Field | Tag byte | Wire type | Encoding |
|---|---|---|---|
| 1 `device_identifier` | `0x0A` | 2 (len‑delimited) | UUID as **36‑char ASCII text** (not 16 packed bytes) |
| 2 `client_generated_token` | `0x10` | 0 (varint) | uint32 as **LEB128 varint** (up to 5 bytes) |
| 3 `device_name` | `0x1A` | 2 (len‑delimited) | UTF‑8 string |

**Vector** — `device_identifier="550e8400-e29b-41d4-a716-446655440000"`,
`token=0x11223344`, `device_name="iPhone"` → **52 bytes**:
```
field1: 0a 24 <36 UTF-8 bytes of "550e8400-...-446655440000">
field2: 10 c4 e6 88 89 01
field3: 1a 06 69 50 68 6f 6e 65        ("iPhone" = 69 50 68 6f 6e 65)
```
Full hex:
```
0a2435353065383430302d653239622d343164342d613731362d34343636353534343030303010c4e68889011a066950686f6e65
```
Token varint: `0x11223344` → `c4 e6 88 89 01`.
**Trap:** the 4‑byte little‑endian form `44 33 22 11` appears ONLY in the `<tag>` input
(§4.9), never in the protobuf. Field 2 is a varint.

### 4.9 Pairing `<tag>`

```
tag = base64( token[4 bytes LITTLE-ENDIAN] || 0x02 0x01 0x00 0x00 )   with '=' stripped
```
The **same** `token` feeds both protobuf field 2 (as a varint) and this tag (as 4 LE bytes);
the plotter cross‑checks them. Standard base64 (RFC 4648, `+`/`/`). The 8‑byte input always
yields 12 chars ending in one `=`, so the stripped tag is **11 chars**.

**Vector** — `token=0x11223344`: input `44 33 22 11 02 01 00 00` → `RDMiEQIBAAA= `→ tag =
`RDMiEQIBAAA`.

**Path‑safety rule:** a raw tag may contain `/` (which would split the URL path) or `+`.
Do **not** percent‑encode. Instead **re‑roll the random token until its tag has no `+` or
`/`** (any token is valid; the body's token field regenerates in lockstep, preserving the
cross‑check). ~70% pass first try. `Pairing.makePathSafeToken()` does this.

### 4.10 HTTP pairing requests (port 80)

Base headers on every request: `Accept: application/json`, `User-Agent: HelmMirror-iOS`.

**(a) Register/pair:**
```
PUT /garmin/bl-ids/<tag>
Content-Type: application/octet-stream
body = MobileDeviceIdentity protobuf bytes (§4.8)
success = HTTP 202  (treat any 2xx as success)
```
On success the plotter shows "a new ActiveCaptain user was added."

**(b) Set role:**
```
PUT /garmin/bl-ids/<tag>/set-role
Content-Type: application/json
body = {"role":"owner"}     (role ∈ "guest" | "owner" | "dealer"; v1 default "owner")
success = any 2xx           (no specific code asserted by the protocol)
```

**(c) Human approval (NOT HTTP):** the user must, once, on the MFD, set the phone to **View
and Control**: *Settings ▸ Communications ▸ Wi‑Fi Network ▸ Wi‑Fi Devices*. This is a global
setting, not per‑user. The session will not stream until it's done. Surface this in the UI.

Persist the app's `device_identifier` (a stable UUID) so repeat runs don't spawn new
ActiveCaptain users.

### 4.11 Video (RTSP/RTP)

- URL: authoritative from EVENT subtype 0; fallback `rtsp://<host>:554/helm_1280x720.h264`.
- SDP: `m=video RTP/AVP 96`, `a=rtpmap:96 H264/90000`, `packetization-mode=1`.
- **UDP transport ONLY.** TCP‑interleaved → `461 Unsupported transport`. Never set VLC
  `:rtsp-tcp`. MobileVLCKit negotiates RTP/AVP/UDP by default, which is correct.

---

## 5. Shared model types (defined in `HelmProtocol.swift`)

These are the exact cross‑file definitions. Use them verbatim; do not redeclare.

```swift
public struct DiscoveredPlotter: Identifiable, Equatable, Hashable {
    public let id: String            // Bonjour service instance name, e.g. "GPSMAP 923"
    public let name: String          // display name
    public var host: String?         // resolved IP or ".local" host; nil until resolved
    public var helmPort: Int         // default 51200
    public var pairingPort: Int      // default 80
    public var txt: [String: String] // merged TXT keys (tag/hasDisplay/version)
    public init(id: String, name: String, host: String? = nil,
                helmPort: Int = 51200, pairingPort: Int = 80, txt: [String: String] = [:])
    public var fallbackRTSPURL: String?   // "rtsp://<host>:554/helm_1280x720.h264" or nil
}

public enum ConnectionState: Equatable {
    case idle
    case discovering
    case connecting
    case handshaking
    case needsPairingApproval           // show "approve on the MFD" instructions
    case streaming(rtspURL: String)
    case disconnected
    case failed(reason: String)
}

public enum HelmInbound: Equatable {
    case context(UInt32)                // touch context id
    case rtspURL(String)                // EVENT subtype 0
    case event(subtype: UInt32, data: Data)
}

public struct HelmTouchPoint: Equatable {
    public var trackId: UInt8           // small stable per-finger id
    public var nx: Double               // 0..1 across displayed video content, left→right
    public var ny: Double               // 0..1 across displayed video content, top→bottom
    public var down: Bool               // true = press/move, false = release
    public init(trackId: UInt8, nx: Double, ny: Double, down: Bool)
}

public enum HelmError: Error, Equatable {
    case http(Int)
    case handshakeTimeout
    case notConnected
    case invalidFrame
    case pairingRejected
    case connectionFailed(String)
}
```

---

## 6. `HelmProtocol.swift` — full public API (frozen)

Byte helpers:

```swift
public struct ByteWriter {
    public init()
    public private(set) var bytes: [UInt8]
    public mutating func u8(_ v: UInt8)
    public mutating func u16(_ v: UInt16)         // little-endian
    public mutating func u32(_ v: UInt32)         // little-endian
    public mutating func varint(_ value: UInt64)  // unsigned LEB128
    public mutating func raw(_ v: [UInt8])
    public mutating func raw(_ v: Data)
    public var data: Data
}

public struct ByteReader {
    public init(_ buf: [UInt8], offset: Int = 0)
    public init(_ data: Data, offset: Int = 0)
    public private(set) var offset: Int
    public var remaining: Int
    public mutating func u8() -> UInt8
    public mutating func u16() -> UInt16          // little-endian
    public mutating func u32() -> UInt32          // little-endian
}
```

Frame codec:

```swift
public struct HelmFrame: Equatable {
    public static let magic: UInt16               // 0xBEEF
    public let type: UInt16
    public let payload: Data
    public init(type: UInt16, payload: Data = Data())
    public func encoded() -> Data
    // Decode exactly one frame from the front of buf; nil if incomplete.
    // Returns the frame and total bytes consumed (8 + payload length).
    public static func decode(_ buf: [UInt8]) -> (frame: HelmFrame, consumed: Int)?
    public static func decode(_ data: Data) -> (frame: HelmFrame, consumed: Int)?
}
```

Messages:

```swift
public enum Helm {
    public static let HELLO: UInt16      // 0x083F
    public static let TOKEN: UInt16      // 0x0AA9
    public static let SUBSCRIBE: UInt16  // 0x1648
    public static let ACQUIRE: UInt16    // 0x1644
    public static let CONTEXT: UInt16    // 0x1645
    public static let EVENT: UInt16      // 0x1649
    public static let TOUCH: UInt16      // 0x164C
    public static let helloTag: UInt16   // 0x9531
    public static let subscribeIndices: [UInt32]   // the 16 indices (model-specific hook)

    public static func hello() -> Data                                   // framed
    public static func token(_ eight: [UInt8]) -> Data                   // framed; precondition count==8
    public static func subscribeFrame(index: UInt32) -> Data             // one framed 0x1648
    public static func subscribeFrames(_ indices: [UInt32] = subscribeIndices) -> Data // 16 frames concatenated
    public static func acquire() -> Data                                 // framed, empty
    public static func touch(ctxId: UInt32, points: [HelmTouchPoint]) -> Data  // framed 0x164C
    public static func parse(_ f: HelmFrame) -> HelmInbound?             // CONTEXT/EVENT → HelmInbound
}
```

Touch encoder:

```swift
public enum HelmTouch {
    public static let unity: Double                          // 65536.0
    public static func fixed16_16(_ v: Double) -> UInt32     // clamp(round(v*65536),0,65536)
    public static func encode(ctxId: UInt32, points: [HelmTouchPoint]) -> Data  // PAYLOAD only (unframed)
}
```

Pairing:

```swift
public enum Pairing {
    public static func identityMessage(deviceId: String, token: UInt32, deviceName: String) -> Data
    public static func tag(for token: UInt32) -> String      // '=' stripped
    public static func makePathSafeToken() -> UInt32         // tag has no '+' or '/'
}
```

> `Helm.touch(...)` returns a **framed** message; `HelmTouch.encode(...)` returns the
> **payload only**. Session code should call `Helm.touch(...)`.

---

## 7. App‑layer files — exact interfaces + behavioral contracts

Implement each file to the signatures below. They compile against `HelmProtocol` only; none
imports another app‑layer file's internals.

### 7.1 `GarminDiscovery.swift`

```swift
import Foundation
import Network
import Combine

@MainActor
public final class GarminDiscovery: ObservableObject {
    @Published public private(set) var plotters: [DiscoveredPlotter]
    /// true once we can infer Local Network access was denied (browsers ready but no
    /// results, or an explicit failure). Drives the "enable Local Network" UI.
    @Published public private(set) var permissionLikelyDenied: Bool

    public init()

    /// Start NWBrowsers for "_garmin-helm._tcp" and "_garmin-bl-id._tcp" in domain "local.".
    /// Merges the two service types per physical plotter (keyed by instance name), filling
    /// helmPort from the helm service and pairingPort/txt from the bl-id service.
    public func start()

    public func stop()

    /// Resolve a plotter's concrete host by opening a throwaway NWConnection to its helm
    /// endpoint and reading currentPath.remoteEndpoint. Returns a copy with `host` set,
    /// or nil on timeout/failure. Prefer a ".local" hostname over a raw IP when available.
    public func resolve(_ plotter: DiscoveredPlotter) async -> DiscoveredPlotter?
}
```

Contract:
- `NWParameters.includePeerToPeer = false` (the MFD is an AP, not AWDL).
- Every browsed type MUST be in `NSBonjourServices` (both are — see §9). Omitting one makes
  that browser silently return nothing.
- Local Network permission prompts on first browse/connect, **device‑only**. Denial is
  silent — surface `permissionLikelyDenied`.
- Internally may keep a private `[String: NWEndpoint]` map (plotter.id → helm endpoint) for
  handing endpoints to `resolve`/session, but this must NOT appear in the public model.

### 7.2 `HelmPairing.swift`

```swift
import Foundation

public struct HelmPairing {
    public let host: String
    public let port: Int
    public init(host: String, port: Int = 80)

    /// Two PUTs: register identity (expect 202) then set-role (expect any 2xx).
    /// - deviceId: a STABLE app UUID (persist it; do not use identifierForVendor semantics
    ///   that reset). Same value on every run so no new ActiveCaptain user is created.
    /// - Uses Pairing.makePathSafeToken()/tag(for:)/identityMessage(...) from HelmProtocol.
    /// Throws HelmError.http(code) on non-2xx (or .pairingRejected).
    public func pair(deviceId: String, deviceName: String, role: String = "owner") async throws
}
```

Contract:
- Build the URL as `http://<host>:<port>/garmin/bl-ids/<tag>` with `percentEncodedPath`
  (tag is already path‑safe). Register: `Content-Type: application/octet-stream`, body =
  protobuf. Set‑role: `Content-Type: application/json`, body = `{"role": role}`.
- ATS: relies on `NSAllowsLocalNetworking` (§9). Prefer the resolved `.local` host when the
  caller has it — that is the unambiguous local‑networking case.

### 7.3 `HelmSession.swift`

```swift
import Foundation
import Network

public actor HelmSession {
    public init(host: String, port: Int = 51200)

    /// Deterministic fallback if no EVENT URL arrives.
    public nonisolated var fallbackRTSPURL: String { get }   // rtsp://<host>:554/helm_1280x720.h264

    public private(set) var contextId: UInt32?
    public private(set) var rtspURL: String?

    /// Open the connection and begin the handshake. Returns an AsyncStream of inbound
    /// messages (context, rtspURL, event). Finishes on disconnect/failure.
    /// Side effects while streaming: caches contextId and rtspURL; runs the 5 s keepalive.
    public func start() -> AsyncStream<HelmInbound>

    /// Frame + send a TOUCH. No-op until contextId is known.
    public func sendTouch(_ points: [HelmTouchPoint])

    public func stop()
}
```

Contract:
- `NWConnection` with `NWProtocolTCP.Options().noDelay = true` (low‑latency touch).
- On `.ready`: send `hello()`, `token(8 random)`, `subscribeFrames()`, `acquire()`, then
  start a keepalive `Task` that re‑sends `subscribeFrames()` every **5 s** (single named
  constant `keepaliveInterval`). Cancel it in `stop()`.
- **Receive/reassembly:** append all received bytes to an internal buffer; loop
  `HelmFrame.decode(buffer)`, removing `consumed` bytes each time, until it returns nil.
  Feed each decoded frame to `Helm.parse`; on `.context(id)` set `contextId`; on
  `.rtspURL(u)` set `rtspURL`; yield each `HelmInbound`.
- **Pairing gate:** if the connection drops or no CONTEXT/URL arrives within a timeout,
  surface a failure the view model maps to `.needsPairingApproval` (the usual cause is the
  MFD "View and Control" step not being set) — see §7.5.
- `sendTouch` frames via `Helm.touch(ctxId:points:)`.

### 7.4 `MirrorPlayerView.swift`

```swift
import SwiftUI

public struct MirrorPlayerView: UIViewRepresentable {
    public let rtspURL: String
    public let videoAspect: CGFloat            // default 1280.0/720.0
    public let onTouch: ([HelmTouchPoint]) -> Void
    public init(rtspURL: String,
                videoAspect: CGFloat = 1280.0/720.0,
                onTouch: @escaping ([HelmTouchPoint]) -> Void)
    public func makeUIView(context: Context) -> UIView
    public func updateUIView(_ uiView: UIView, context: Context)
    public static func dismantleUIView(_ uiView: UIView, coordinator: ())
}
```

Backing UIView contract (`import MobileVLCKit`):
- Owns a `VLCMediaPlayer` with `player.drawable = self`; `backgroundColor = .black`;
  `isMultipleTouchEnabled = true`.
- `play`: `VLCMedia(url:)` with options — **do NOT set `:rtsp-tcp`** — 
  `network-caching: 150`, `live-caching: 150`, `clock-jitter: 0`, `clock-synchro: 0`,
  `rtsp-frame-buffer-size: 500000`. (`network-caching` 100–200 ms is the latency knob.)
- Touch capture: override `touchesBegan/Moved/Ended/Cancelled`. Map each `UITouch` to a
  stable small `track_id` via `ObjectIdentifier` (assign next free id on first sight,
  release on end/cancel). `down = true` for began/moved, `false` for ended/cancelled.
  Normalize `location(in:)` against the **content rect**.
- **Aspect rule:** present the view at 16:9 (`.aspectRatio(videoAspect, contentMode: .fit)`)
  so `contentRect == bounds` and `nx = p.x/bounds.width`, `ny = p.y/bounds.height` are
  exact. If the view is ever non‑16:9, compute the letterboxed content rect and normalize
  against it (clamp outside touches):
  ```
  viewAspect > videoAspect → pillarbox: w = h*aspect, x = (W-w)/2
  else                     → letterbox: h = w/aspect, y = (H-h)/2
  nx = (p.x-rect.minX)/rect.width ; ny = (p.y-rect.minY)/rect.height
  ```
- Optionally batch `event.coalescedTouches(for:)` into one `onTouch` call for smoother drags.

### 7.5 `ContentView.swift` (+ view model)

```swift
import SwiftUI

@MainActor
public final class HelmMirrorViewModel: ObservableObject {
    @Published public private(set) var state: ConnectionState
    @Published public private(set) var plotters: [DiscoveredPlotter]

    public init()

    public func startDiscovery()
    /// Resolve → pair (if needed) → open session → drive `state` and start video on URL.
    public func connect(to plotter: DiscoveredPlotter)
    /// User tapped "I've approved on the plotter" — re-attempt the session.
    public func retryAfterApproval()
    public func disconnect()
    /// Forward normalized touches from MirrorPlayerView to the live session.
    public func sendTouch(_ points: [HelmTouchPoint])
}

public struct ContentView: View {
    public init()
    public var body: some View
}
```

UI contract:
- `.idle`/`.discovering`: list `plotters` (name + host); tap → `connect`.
- `.connecting`/`.handshaking`: progress.
- `.needsPairingApproval`: show the exact MFD instruction text ("Settings ▸ Communications ▸
  Wi‑Fi Network ▸ Wi‑Fi Devices ▸ set your phone to *View and Control*") + a **Retry** button
  → `retryAfterApproval()`.
- `.streaming(rtspURL:)`: full‑screen `MirrorPlayerView(rtspURL:, onTouch: vm.sendTouch)` at
  16:9 on black.
- `.failed(reason:)`: message + Retry/Back. If discovery reports `permissionLikelyDenied`,
  show "Local Network access is off — enable it in Settings."
- Landscape‑only (matches Info.plist).

### 7.6 `HelmMirrorApp.swift`

```swift
import SwiftUI

@main
public struct HelmMirrorApp: App {
    public init()
    public var body: some Scene    // WindowGroup { ContentView() }
}
```

---

## 8. Consolidated test‑vector table (all green)

| # | What | Input | Expected (hex unless noted) |
|---|---|---|---|
| 1 | HELLO frame | — | `3f08efbe020000003195` |
| 2 | TOKEN frame | token `deadbeef01020304` | `a90aefbe08000000deadbeef01020304` |
| 3 | ACQUIRE frame | — | `4416efbe00000000` |
| 4 | SUBSCRIBE idx 0x0b | — | `4816efbe040000000b000000` |
| 5 | SUBSCRIBE idx 0x00 | — | `4816efbe0400000000000000` |
| 6 | SUBSCRIBE burst | — | 192 bytes; first frame idx 0x0b, last idx 0x0c |
| 7 | TOUCH press | ctx 5, (0.5,0.5), down | `4c16efbe18000000050000000100000000008000000080000001000000000000` |
| 8 | TOUCH release | ctx 5, (0.5,0.5), up | `4c16efbe18000000050000000100000000008000000080000000000000000000` |
| 9 | fixed16_16 | 0.0 / 0.25 / 0.5 / 1.0 / 2.0 / −1.0 | 0 / 0x4000 / 0x8000 / 0x10000 / 0x10000 / 0 |
| 10 | CONTEXT parse | `01000000 05000000` | `.context(5)` |
| 11 | EVENT subtype 0 | `00000000`+len+url | `.rtspURL("rtsp://172.16.6.0:554/helm_1280x720.h264")` |
| 12 | protobuf identity | uuid/0x11223344/"iPhone" | 52 bytes; `0a24…10c4e68889011a066950686f6e65` |
| 13 | token varint | 0x11223344 | `c4e6888901` |
| 14 | `<tag>` | 0x11223344 | `RDMiEQIBAAA` |
| 15 | path‑safe token | 200+ samples | tag never contains `+`, `/`, or `=` |

Full protobuf (#12):
`0a2435353065383430302d653239622d343164342d613731362d34343636353534343030303010c4e68889011a066950686f6e65`

Run: `swift test` (root `Package.swift` compiles only `HelmProtocol.swift` + the tests).
If `swift test` reports `no such module 'XCTest'`, select full Xcode:
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

---

## 9. Build / project configuration

**XcodeGen (`project.yml`)** — one iOS app target `HelmMirror` (bundle id
`com.jimmy.helmmirror`, iOS 16, SwiftUI, sources = `Sources/`, depends on the local
`HelmProtocol` package) plus a macOS `bundle.unit-test` target compiling only
`Sources/HelmProtocol.swift` + `Tests/HelmWireTests`. Generated `Info.plist` keys:

```
NSLocalNetworkUsageDescription = "HelmMirror connects to your Garmin chartplotter…"
NSBonjourServices = [ _garmin-helm._tcp, _garmin-bl-id._tcp ]
NSAppTransportSecurity = { NSAllowsLocalNetworking: true }
UISupportedInterfaceOrientations = landscape left/right (iPhone + iPad)
```
`NSAllowsLocalNetworking = true` exempts `.local` names, link‑local, and RFC‑1918 ranges
(incl. `172.16/12`) from ATS — no `NSAllowsArbitraryLoads` (keeps App Review clean).

**MobileVLCKit via CocoaPods** (`Podfile`): `pod 'MobileVLCKit', '~> 3.6.0'`,
`use_frameworks!`. There is no reliable stable SwiftPM artifact for VLC 3.x; do **not** add
VLC under XcodeGen `packages:` (double‑link). Bootstrap:
`xcodegen generate && pod install && open HelmMirror.xcworkspace`. Always open the
`.xcworkspace` after `pod install`.

**Package.swift (alt)** — macOS wire verification only: library target lists **only**
`Sources/HelmProtocol.swift`; test target = `Tests/HelmWireTests`. No app‑layer sources, no
VLC. `swift test` runs on a plain Mac (with full Xcode toolchain selected).

Signing: set your Team in Xcode. `DEVELOPMENT_TEAM` is blank in `project.yml` on purpose.

---

## 10. Open risks & model‑specific hooks

- **`Helm.subscribeIndices` is a captured constant** from the 923xsv. It is the most likely
  thing to differ on other MFDs. It is exposed as a public array so it can be swapped without
  touching the codec; `subscribeFrames(_:)` accepts an override.
- **Keepalive interval (5 s)** is asserted by ground truth but not by the reference client;
  keep it a single named constant and confirm empirically (the plotter's hard timeout is
  ~30 s).
- **RTSP URL string bytes** have no verified sample; EVENT subtype‑0 parsing is implemented
  defensively (UTF‑8, NUL/whitespace‑trimmed) with a deterministic fallback.
- **Device‑only reality:** Local Network permission + RTSP video do not work in the
  Simulator; the MFD is a Wi‑Fi AP the phone must join. All hardware verification happens on
  device.
- **Legal/safety:** unofficial protocol; possible EULA conflict; never use for navigation.

---

## Appendix A — `Sources/HelmProtocol.swift` (frozen source, for reference)

The complete Foundation‑only core is in `Sources/HelmProtocol.swift`. Its public API is §6;
its shared types are §5. Implementers depend on that file as‑is and must not modify it. It
compiles standalone (`swift build --target HelmProtocol`) and all §8 vectors pass.
