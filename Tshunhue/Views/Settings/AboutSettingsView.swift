//
//  PrivacySettingsView.swift
//  Tshunhue
//
//  Presents app information in settings view.
//

import SwiftUI

/// The reusable  app information settings section.
struct AboutSettingsView: View {
    #if os(macOS)
    @State private var showingPrivacy = false
    #endif

    var body: some View {
        Section("Privacy") {
            #if os(macOS)
            Button("Privacy Policy", systemImage: "eye") { showingPrivacy = true }
            #else
            NavigationLink(value: SettingsRoute.privacyPolicy) {
                Label("Privacy Policy", systemImage: "eyes")
            }
            NavigationLink(value: SettingsRoute.about) {
                Label("About Tshunhue", systemImage: "info.circle")
            }
            #endif
        }
        #if os(macOS)
        .sheet(isPresented: $showingPrivacy) {
            NavigationStack {
                PolicyView()
            }
        }
        #endif
    }
}

#if DEBUG
#Preview("Privacy Settings") {
    Form {
        AboutSettingsView()
    }
    .formStyle(.grouped)
}
#endif
