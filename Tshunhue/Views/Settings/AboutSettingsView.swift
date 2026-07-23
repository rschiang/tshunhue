//
//  PrivacySettingsView.swift
//  Tshunhue
//
//  Presents app information in settings view.
//

import SwiftUI

#if os(iOS)
/// The reusable  app information settings section.
struct AboutSettingsView: View {
    var body: some View {
        Section("Privacy") {
            NavigationLink(value: SettingsRoute.privacyPolicy) {
                Label("Privacy Policy", systemImage: "eyes")
            }
            NavigationLink(value: SettingsRoute.about) {
                Label("About Tshunhue", systemImage: "info.circle")
            }
        }
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
#endif
