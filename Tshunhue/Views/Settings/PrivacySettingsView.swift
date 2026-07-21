//
//  PrivacySettingsView.swift
//  Tshunhue
//
//  Presents privacy information and links to supporting app information.
//

import SwiftUI

/// The reusable privacy settings section with an optional About action.
struct PrivacySettingsView: View {
    /// Opens the platform's About presentation when supplied.
    var onShowAbout: (() -> Void)?
    @State private var showingPrivacy = false

    /// Creates privacy settings with an optional About action.
    init(onShowAbout: (() -> Void)? = nil) {
        self.onShowAbout = onShowAbout
    }

    var body: some View {
        Section("Privacy") {
            Text("Tshunhue has no accounts, analytics, or telemetry. Source and image hosts receive ordinary network requests when content is synchronized or displayed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Privacy Policy", systemImage: "hand.raised") { showingPrivacy = true }
            if let onShowAbout {
                Button("About Tshunhue", systemImage: "info.circle", action: onShowAbout)
            }
        }
        .sheet(isPresented: $showingPrivacy) {
            PolicyView()
        }
    }
}

#if DEBUG
#Preview("Privacy Settings") {
    Form {
        PrivacySettingsView(onShowAbout: {})
    }
    .formStyle(.grouped)
}
#endif
