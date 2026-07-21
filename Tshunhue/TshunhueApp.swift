//
//  TshunhueApp.swift
//  Tshunhue
//
//  Defines the application entry point, scenes, and lifecycle refresh behavior.
//

import SwiftUI

@main
/// The shared SwiftUI application entry point for macOS and iOS.
struct TshunhueApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.refreshWhenActive() }
                }
                .frame(minWidth: 720, minHeight: 520)
        }
        #if os(macOS)
        Settings {
            SettingsView(model: model)
        }
        #endif
    }
}
