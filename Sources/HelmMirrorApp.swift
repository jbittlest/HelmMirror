//
//  HelmMirrorApp.swift
//  HelmMirror
//
//  @main entry point (SPEC §7.6). Single-window SwiftUI scene hosting ContentView.
//  Orientation is pinned to landscape via Info.plist (see project.yml), matching
//  the plotter's 1280x720 mirror; nothing to force in code.
//

import SwiftUI

@main
public struct HelmMirrorApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
