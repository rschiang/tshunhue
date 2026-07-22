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
        #if os(macOS)
        WindowGroup {
            applicationContent
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            AboutCommands()
        }

        Settings {
            SettingsView(model: model)
        }

        Window("About Tshunhue", id: AboutCommands.windowID) {
            AboutView()
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
        }
        .commandsRemoved()
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowManagerRole(.associated)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        #else
        WindowGroup {
            applicationContent
        }
        #endif
    }

    /// The shared root content and lifecycle behavior hosted by each platform scene.
    private var applicationContent: some View {
        ContentView(model: model)
            .task { await model.start() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refreshWhenActive() }
            }
    }
}

#if os(macOS)
/// Replaces the standard application-info item with Tshunhue's custom About window.
private struct AboutCommands: Commands {
    /// The stable scene identifier used by the About menu command.
    static let windowID = "about"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tshunhue") {
                openWindow(id: Self.windowID)
            }
        }
    }
}
#endif
