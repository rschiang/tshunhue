//
//  StorageSettingsView.swift
//  Tshunhue
//
//  Presents cache and recent-item storage controls.
//

import SwiftUI

/// The reusable settings section for local image and history storage.
struct StorageSettingsView: View {
    /// The model used to inspect and clear local storage.
    @ObservedObject var model: AppModel

    var body: some View {
        Section("Storage") {
            LabeledContent("Image Cache", value: formattedCacheSize)
            Button("Clear Image Cache", systemImage: "trash") {
                Task { await model.clearCache() }
            }
            Button("Clear Recent Items", systemImage: "clock.badge.xmark") {
                Task { await model.clearRecents() }
            }
        }
        .task { await model.refreshCacheSize() }
    }

    /// A localized, human-readable representation of the image cache size.
    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(model.cacheByteCount), countStyle: .file)
    }
}

#if DEBUG
#Preview("Storage Settings") {
    Form {
        StorageSettingsView(model: PreviewData.model())
    }
    .formStyle(.grouped)
}
#endif
