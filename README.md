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
- **CocoaPods** (for the video library): `brew install cocoapods` (or `sudo gem install cocoapods`)
- An iPhone or iPad (iOS 16+), a USB cable, and a free Apple ID for signing.

---

## Build & run (step by step)

From this folder (`HelmMirror/`) in Terminal:

```bash
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2. Pull in the video library (MobileVLCKit) via CocoaPods
pod install

# 3. Open the WORKSPACE (not the .xcodeproj — Pods live in the workspace)
open HelmMirror.xcworkspace
```

Then in Xcode:

4. Select the **HelmMirror** scheme (top bar).
5. Click the project ▸ **HelmMirror** target ▸ **Signing & Capabilities** ▸ pick your
   **Team** (your Apple ID). Xcode will auto‑create a provisioning profile.
6. Plug in your iPhone, select it as the run destination (top bar).
7. Press **▶ Run**. First run: on the iPhone, go to **Settings ▸ General ▸ VPN & Device
   Management** and **trust** your developer certificate, then Run again.

> Re‑run `xcodegen generate && pod install` any time you change `project.yml` or the
> `Podfile`.

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

This uses the root `Package.swift`, which compiles **only** `Sources/HelmProtocol.swift`
plus the tests — no Simulator, no VLC.

> **If `swift test` says `no such module 'XCTest'`:** your Mac is using the Command Line
> Tools toolchain, which has no XCTest. Point it at full Xcode once:
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and re‑run.

---

## If the video is black / VLC trouble

- **Give it a second or two.** RTSP startup + buffering (`network-caching`) means the
  first frame isn't instant.
- **Confirm you're on the plotter's Wi‑Fi** and the plotter screen is on.
- **UDP is mandatory.** The plotter only serves RTSP over **UDP**; it rejects TCP with
  `461 Unsupported transport`. Never enable VLC's `:rtsp-tcp` option.
- **Latency too high?** Lower `network-caching`/`live-caching` (try 100–150 ms) in
  `MirrorPlayerView`. Too low and you get stutter; 100–200 ms is the sweet spot.
- **Still black?** Sanity‑check the stream outside the app on the Mac (same Wi‑Fi):
  `ffplay -rtsp_transport udp rtsp://<plotter-ip>:554/helm_1280x720.h264`
  or open that URL in desktop VLC. If that's black too, it's the plotter/link, not the app.
- **Touches land in the wrong place?** The mirror must be shown at the native
  **1280×720 (16:9)** aspect so touch normalization matches the video content exactly
  (see the touch‑mapping note in `SPEC.md`).

---

## Project layout

```
HelmMirror/
├─ project.yml        # XcodeGen: the iOS app + a macOS wire-test target
├─ Podfile            # CocoaPods: MobileVLCKit only
├─ Package.swift      # ALT manifest: `swift test` for the wire core, macOS-only
├─ README.md          # this file
├─ SPEC.md            # the frozen implementation spec (byte layouts + every interface)
├─ Sources/
│  ├─ HelmProtocol.swift     # Foundation-only wire core (architect-owned; do not edit)
│  ├─ GarminDiscovery.swift  # NWBrowser Bonjour discovery            (implement per SPEC)
│  ├─ HelmPairing.swift      # URLSession pairing + set-role          (implement per SPEC)
│  ├─ HelmSession.swift      # NWConnection TCP session + keepalive   (implement per SPEC)
│  ├─ MirrorPlayerView.swift # VLCMediaPlayer + touch capture         (implement per SPEC)
│  ├─ ContentView.swift      # SwiftUI UI + view model                (implement per SPEC)
│  └─ HelmMirrorApp.swift    # @main App                              (implement per SPEC)
└─ Tests/HelmWireTests/
   └─ HelmWireTests.swift    # byte-exact vectors (architect-owned)
```

`Sources/HelmProtocol.swift`, `Tests/HelmWireTests/HelmWireTests.swift`, `project.yml`,
`Package.swift`, `Podfile`, `README.md`, and `SPEC.md` are the frozen scaffold — **do not
edit them.** Implement the remaining `Sources/*.swift` files exactly to the interfaces in
`SPEC.md`.
