//
//  SettingsView.swift
//  Tshunhue
//
//  Composes reusable settings sections for each supported platform.
//

import SwiftUI

#if os(iOS)
/// Lightweight destinations owned by the iOS Settings sheet navigation stack.
enum SettingsRoute: Hashable {
    case addSource
    case privacyPolicy
    case about
}
#endif

/// The settings entry point shared by the macOS settings scene and iOS sheet.
struct SettingsView: View {
    /// The model that owns source, refresh, and storage settings.
    @ObservedObject var model: AppModel
    var body: some View {
        #if os(macOS)
        TabView {
            Form {
                SourcesSettingsView(model: model)
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Sources", systemImage: "tray.full")
            }

            Form {
                StorageSettingsView(model: model)
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Storage", systemImage: "externaldrive")
            }

            Form {
                AboutSettingsView()
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Privacy", systemImage: "hand.raised")
            }
        }
        .frame(idealWidth: 520, idealHeight: 480)
        #else
        Form {
            SourcesSettingsView(model: model)
            StorageSettingsView(model: model)
            AboutSettingsView()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #endif
    }
}

#if DEBUG
#Preview("Settings") {
    #if os(iOS)
    NavigationStack {
        SettingsView(model: PreviewData.model())
    }
    #else
    SettingsView(model: PreviewData.model())
    #endif
}
#endif
