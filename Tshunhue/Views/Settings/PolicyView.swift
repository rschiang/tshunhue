//
//  PolicyView.swift
//  Tshunhue
//
//  Displays Tshunhue's local-data and network privacy disclosure.
//

import SwiftUI

/// The app's concise local-data and network privacy disclosure.
struct PolicyView: View {
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        ScrollView {
            Text("Tshunhue has no accounts, analytics, advertising, or telemetry. Catalogs and images are requested directly from the HTTPS hosts you configure, so those hosts receive ordinary network information such as your IP address. Search history and recent transfers remain on this device. Tshunhue does not inspect or transmit text typed with its keyboard extension.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Privacy Policy")
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .frame(idealWidth: 480, idealHeight: 320)
        #endif
    }
}

#if DEBUG
#Preview("Privacy Policy") {
    NavigationStack {
        PolicyView()
    }
}
#endif
