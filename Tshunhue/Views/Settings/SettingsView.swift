//
//  SettingsView.swift
//  Tshunhue
//
//  Composes reusable settings sections for each supported platform.
//

import SwiftUI

/// The settings entry point shared by the macOS settings scene and iOS sheet.
struct SettingsView: View {
    /// The model that owns source, refresh, and storage settings.
    @ObservedObject var model: AppModel
    @State private var showingAbout = false

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
                PrivacySettingsView()
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
            PrivacySettingsView { showingAbout = true }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .navigationDestination(isPresented: $showingAbout) {
            AboutView()
                .navigationTitle("About Tshunhue")
        }
        #endif
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView(model: PreviewData.model())
}
#endif
