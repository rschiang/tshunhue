//
//  TshunhueApp.swift
//  Tshunhue
//
//  Created by 姜柏任 on 2026/7/21.
//

import SwiftUI

@main
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
