# HelmMirror

A universal iOS app that discovers **any Garmin chartplotter (MFD)** on the boat's
Wi‑Fi and **mirrors its screen** — and lets you tap/drag the mirror to control the
plotter remotely, just like Garmin's ActiveCaptain "Helm" feature.

- Finds the plotter automatically over Wi‑Fi (Bonjour/mDNS).
- Shows the live video (RTSP/H.264) full‑screen in landscape.
- Sends your touches back to the plotter (single‑finger tap and drag).

---

## ✅ Verify the protocol right now (30 seconds, no Xcode needed)

Before installing anything big, you can prove the byte-level protocol layer is correct
on this Mac today. From this folder in Terminal:

```bash
swift run helmverify
```

Expected last line: `PASS — 43 vectors verified.`

This checks every frame header, the handshake frames, the touch encoding, the pairing
protobuf and the `<tag>` derivation against the reverse-engineered spec. It uses only
Foundation, so it works with the **Command Line Tools** alone.

(`swift test` runs the same vectors via XCTest, but XCTest ships only with full Xcode.
If you see `no such module 'XCTest'`, that's why — use `swift run helmverify` instead.)

---

## 🚨 You need full Xcode to build the app

**This Mac currently has only the Command Line Tools installed, not Xcode.** You cannot
build an iOS app without it — there's no iOS SDK and no way to deploy to your iPhone.

Install **Xcode** free from the Mac App Store (it's a large download, roughly 7–10 GB,
so do it on good Wi-Fi), then run once:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
```

Everything in "Build & run" below assumes that's done.

---

## ⚠️ Honest caveats — read this first

- **Unofficial.** This talks to Garmin's private, reverse‑engineered protocol. It is
  **not** endorsed by Garmin and may violate the device/app EULA. Use at your own risk,
  and **never rely on it for navigation or safety.** Keep using the real MFD.
- **Verified on exactly one model.** The wire protocol here was reverse‑engineered
  against a **Garmin GPSMAP 923xsv**. Other models may differ (especially the
  `subscribeIndices` constant). Treat "universal" as "best effort."
- **Untested against real hardware.** The byte‑level protocol logic is verified locally
  (43 passing vectors — see above), but the end‑to‑end app has never been run against an
  actual plotter. The first real test is you, on the boat. Expect to debug on the water.
- **Physical device only.** Local Network permission and RTSP video do **not** work in
  the iOS Simulator. You must run on a real iPhone/iPad joined to the plotter's Wi‑Fi.

---

## What you need

- A Mac.
- **Xcode** (from the Mac App Store) — the full app, not just Command Line Tools.
- **Homebrew** (https://brew.sh) and **XcodeGen**: `brew install xcodegen`
- Nothing else. The video player is native Swift (Foundation + Network + AVFoundation);
  there are **no third-party dependencies and no CocoaPods**.
- An iPhone or iPad (iOS 16+), a USB cable, and a free Apple ID for signing.

---

## Build & run (step by step)

From this folder (`HelmMirror/`) in Terminal:

```bash
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2. Open it
open HelmMirror.xcodeproj
```

Then in Xcode:

3. Select the **HelmMirror** scheme (top bar).
4. Click the project ▸ **HelmMirror** target ▸ **Signing & Capabilities** ▸ pick your
   **Team** (your Apple ID). Xcode will auto‑create a provisioning profile.
5. Plug in your iPhone, select it as the run destination (top bar).
6. Press **▶ Run**. First run: on the iPhone, go to **Settings ▸ General ▸ VPN & Device
   Management** and **trust** your developer certificate, then Run again.

> Re‑run `xcodegen generate` any time you change `project.yml` or add a source file.
> Or build straight from the command line:
>
> ```bash
> xcodebuild -project HelmMirror.xcodeproj -scheme HelmMirror \
>   -destination 'generic/platform=iOS' -allowProvisioningUpdates build
> ```

---

## Using it on the boat

1. **Join the plotter's Wi‑Fi.** The MFD is its own access point. On the iPhone:
   **Settings ▸ Wi‑Fi**, join the Garmin network (turn on the MFD's Wi‑Fi first if
   needed: on the plotter, *Settings ▸ Communications ▸ Wi‑Fi Network*).
2. **Launch HelmMirror.** The first time, iOS asks for **Local Network** permission —
   tap **Allow** (without it, the app can't find the plotter).
3. The app lists discovered plotters. **Tap yours** to connect.
4. **One‑time approval on the plotter.** The app will pair, then ask you to approve the
   phone **on the MFD itself**:
   > On the plotter: **Settings ▸ Communications ▸ Wi‑Fi Network ▸ Wi‑Fi Devices**,
   > select your phone, set it to **"View and Control."**
   This is a global, one‑time setting. After it's set, tap **Retry** in the app.
5. The mirror appears. Tap and drag on it to drive the plotter.

---

## Verify the wire logic on your Mac (no phone, no Xcode project needed)

The byte‑level protocol (frame codec, protobuf pairing, `<tag>`, touch encoding) is
covered by fast, dependency‑free tests:

```bash
swift test
```

This uses the root `Package.swift`, which compiles `Sources/HelmProtocol.swift` plus
`Sources/RTSPCore/` (the pure half of the RTSP/RTP/H.264 player) and the tests — no
Simulator, no Xcode project, no third-party code.

There is also a Foundation-only harness that runs with just the Command Line Tools:

```bash
swift run helmverify
```

> **If `swift test` says `no such module 'XCTest'`:** your Mac is using the Command Line
> Tools toolchain, which has no XCTest. Point it at full Xcode once:
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and re‑run.

---

## If the video is black

**Read the on-screen log first.** The app prints the literal RTSP request and response
lines under the video — `> DESCRIBE …`, `< RTSP/1.0 200 OK`, `sdp: video pt=96 …`. Where
that list stops is the answer; you should not need a Mac or a cable to diagnose it.

- **Give it a second or two.** Handshake plus the first keyframe is not instant.
- **Confirm you're on the plotter's Wi‑Fi** and the plotter screen is on.
- **UDP first, TCP as a fallback.** The player requests `RTP/AVP` (UDP) and falls back to
  `$`-interleaved TCP exactly once if SETUP is refused or no RTP arrives within 3 s. Both
  attempts are visible in the log.
- **The log stops after `< RTSP/1.0 200 OK` for PLAY.** RTP is not reaching the phone —
  check that nothing on the network is blocking UDP, and watch for the automatic
  `no RTP over UDP -> retrying interleaved TCP` line.
- **Still black?** Sanity‑check the stream outside the app on the Mac (same Wi‑Fi):
  `ffplay -rtsp_transport udp rtsp://<plotter-ip>:554/helm_1280x720.h264`
  If that's black too, it's the plotter/link, not the app.
- **Touches land in the wrong place?** The mirror must be shown at the native
  **1280×720 (16:9)** aspect so touch normalization matches the video content exactly
  (see the touch‑mapping note in `SPEC.md`).

---

## Project layout

```
HelmMirror/
├─ project.yml        # XcodeGen: the iOS app (no CocoaPods, no dependencies)
├─ Package.swift      # ALT manifest: the pure layers + helmverify + the Mac bridge
├─ README.md          # this file
├─ SPEC.md            # the frozen protocol spec (byte layouts + every interface)
├─ SPEC-RTSP.md       # the frozen spec for the native RTSP/RTP/H.264 player
├─ Sources/
│  ├─ HelmProtocol.swift     # Foundation-only wire core (architect-owned; do not edit)
│  ├─ GarminDiscovery.swift  # NWBrowser Bonjour discovery
│  ├─ HelmPairing.swift      # URLSession pairing + set-role
│  ├─ HelmSession.swift      # NWConnection TCP session + keepalive
│  ├─ MirrorPlayerView.swift # SwiftUI wrapper + touch capture + diagnostics
│  ├─ ContentView.swift      # SwiftUI UI + view model
│  ├─ HelmMirrorApp.swift    # @main App
│  ├─ RTSPCore/             # PURE (Foundation only) — also built by Package.swift
│  │  ├─ RTSPMessage.swift  #   RTSP request build / response + `$` frame decode
│  │  ├─ SDP.swift          #   SDP parse, H.264 track, control-URL joining
│  │  ├─ RTPPacket.swift    #   RTP header parse, seq arithmetic, reorder buffer
│  │  └─ H264Depacketizer.swift  # RFC 6184 -> AVCC access units
│  └─ RTSP/                 # PLATFORM (Network / AVFoundation / UIKit)
│     ├─ RTSPClient.swift      # the RTSP conversation + interleaved demux
│     ├─ RTPUDPTransport.swift # the UDP RTP/RTCP socket pair
│     ├─ H264VideoView.swift   # AVSampleBufferDisplayLayer + format description
│     └─ RTSPVideoSession.swift# the glue: client + transport -> access units
├─ Verify/main.swift  # the Foundation-only vector harness (`swift run helmverify`)
└─ Tests/HelmWireTests/
   └─ HelmWireTests.swift    # byte-exact vectors under XCTest (architect-owned)
```

`Sources/HelmProtocol.swift`, `Tests/HelmWireTests/HelmWireTests.swift`, `project.yml`,
`Package.swift`, `README.md`, and `SPEC.md` are the frozen scaffold — **do not
edit them.** Implement the remaining `Sources/*.swift` files exactly to the interfaces in
`SPEC.md`.
