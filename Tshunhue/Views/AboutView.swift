//
//  AboutView.swift
//  Tshunhue
//
//  Displays Tshunhue's application identity and version.
//

import SwiftUI

/// A compact, presentation-independent application identity view.
struct AboutView: View {
    /// The user-facing short version from the application bundle.
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.macro")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Tshunhue")
                .font(.title.bold())
            Text("Spring flowers — a community meme image browser.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Version \(version)")
                .font(.caption)
        }
        .padding(32)
    }
}

#if DEBUG
#Preview("About") {
    AboutView()
        .frame(idealWidth: 420, idealHeight: 300)
}
#endif
