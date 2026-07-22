//
//  ContentView.swift
//  Tshunhue
//
//  Selects the platform-specific root while retaining shared presentation preferences.
//

import SwiftUI

/// The adaptive root view for Tshunhue's macOS and iOS experiences.
struct ContentView: View {
    /// The shared application state and command model.
    @ObservedObject var model: AppModel
    @AppStorage("groupFrames") private var groupFrames = false

    var body: some View {
        #if os(macOS)
        MacContentView(model: model, groupFrames: $groupFrames)
        #else
        iOSContentView(model: model, groupFrames: $groupFrames)
        #endif
    }
}

#if DEBUG
#Preview("Content") { ContentView(model: PreviewData.model()) }
#endif
