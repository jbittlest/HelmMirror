// swift-tools-version:5.9
//
//  Package.swift
//
//  Builds everything that does NOT require Xcode:
//
//    swift run helmverify    — 43 byte vectors for the wire protocol
//    swift run helmbridge    — the Mac bridge: talks to the Garmin, serves the
//                              mirror to any phone browser on the same Wi-Fi
//
//  The iOS app (Sources/ContentView.swift, MirrorPlayerView.swift,
//  HelmMirrorApp.swift) needs UIKit/SwiftUI-iOS/MobileVLCKit and is built by the
//  Xcode project generated from project.yml — never by this manifest.
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
                "Info.plist"
            ],
            sources: ["HelmProtocol.swift"]
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
