// swift-tools-version:5.9
//
//  Package.swift  (ALTERNATE manifest — macOS wire verification only)
//
//  This builds the byte-level protocol core in isolation so it can be verified on a
//  plain Mac with NO Xcode project, NO Simulator, and NO MobileVLCKit.
//
//  The library target lists ONLY Sources/HelmProtocol.swift. The app-layer files
//  (GarminDiscovery / HelmPairing / HelmSession / MirrorPlayerView / ContentView /
//  HelmMirrorApp) import Network / UIKit / SwiftUI / MobileVLCKit and are built by
//  the Xcode project generated from project.yml — never by this manifest.
//
//  Two ways to verify the wire protocol:
//
//    swift run helmverify    <- works with Command Line Tools alone (recommended)
//    swift test              <- requires FULL Xcode (XCTest does not ship with CLT)
//

import PackageDescription

let package = Package(
    name: "HelmProtocol",
    platforms: [
        .macOS(.v12),
        .iOS(.v16)
    ],
    products: [
        .library(name: "HelmProtocol", targets: ["HelmProtocol"]),
        .executable(name: "helmverify", targets: ["HelmVerify"])
    ],
    targets: [
        // Deliberately compiles a single file. Do not add the app-layer sources here.
        // The app-layer files live in Sources/ but belong to the iOS app target only,
        // so they are excluded explicitly (they need UIKit/Network/VLC).
        .target(
            name: "HelmProtocol",
            path: "Sources",
            exclude: [
                "GarminDiscovery.swift",
                "HelmPairing.swift",
                "HelmSession.swift",
                "MirrorPlayerView.swift",
                "ContentView.swift",
                "HelmMirrorApp.swift"
            ],
            sources: ["HelmProtocol.swift"]
        ),
        // Foundation-only vector harness. No XCTest, so it runs with only the
        // Xcode Command Line Tools installed.
        .executableTarget(
            name: "HelmVerify",
            dependencies: ["HelmProtocol"],
            path: "Verify"
        ),
        // Same vectors as XCTest, for machines with full Xcode.
        .testTarget(
            name: "HelmWireTests",
            dependencies: ["HelmProtocol"],
            path: "Tests/HelmWireTests"
        )
    ]
)
