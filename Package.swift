// swift-tools-version:5.9
//
//  Package.swift
//
//  Builds everything that does NOT require Xcode:
//
//    swift run helmverify    — byte vectors for the wire protocol AND for the
//                              native RTSP/RTP/H.264 player's pure layer
//    swift run helmbridge    — the Mac bridge: talks to the Garmin, serves the
//                              mirror to any phone browser on the same Wi-Fi
//
//  The iOS app (Sources/ContentView.swift, MirrorPlayerView.swift,
//  HelmMirrorApp.swift, Sources/RTSP/) needs UIKit/SwiftUI-iOS/Network/
//  AVFoundation and is built by the Xcode project generated from project.yml —
//  never by this manifest. There are no third-party dependencies.
//

import PackageDescription

let package = Package(
    name: "HelmMirror",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "HelmProtocol", targets: ["HelmProtocol"]),
        .executable(name: "helmverify", targets: ["HelmVerify"]),
        .executable(name: "helmbridge", targets: ["HelmBridge"])
    ],
    targets: [
        // Foundation-only wire core, shared by the iOS app and the bridge.
        //
        // `Sources/RTSPCore/` joins it: RTSP message syntax, SDP, RTP headers and
        // RFC 6184 depacketization are all pure byte-level code, and keeping them
        // here is what lets `swift run helmverify` pin them without Xcode.
        // `Sources/RTSP/` is excluded — that half needs Network/AVFoundation/UIKit.
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

        // Foundation-only vector harness — runs with Command Line Tools alone.
        .executableTarget(
            name: "HelmVerify",
            dependencies: ["HelmProtocol"],
            path: "Verify"
        ),

        // The macOS bridge. Web/ is copied in as a resource and served at runtime
        // via Bundle.module.
        .executableTarget(
            name: "HelmBridge",
            dependencies: ["HelmProtocol"],
            path: "Bridge",
            resources: [.copy("Web")]
        ),

        // Same vectors under XCTest, for machines with full Xcode.
        .testTarget(
            name: "HelmWireTests",
            dependencies: ["HelmProtocol"],
            path: "Tests/HelmWireTests"
        )
    ]
)
