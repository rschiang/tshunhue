//
//  SourcesSettingsView.swift
//  Tshunhue
//
//  Presents source, category, and synchronization settings.
//

import SwiftUI

/// Reusable settings sections for managing sources and their refresh schedule.
struct SourcesSettingsView: View {
    /// The model used to manage sources, categories, and refreshes.
    @ObservedObject var model: AppModel
    @State private var showingAddSource = false

    var body: some View {
        Group {
            Section("Sources") {
                if model.sources.isEmpty {
                    ContentUnavailableView(
                        "No Sources",
                        systemImage: "tray",
                        description: Text("Add an HTTPS index URL to begin.")
                    )
                }
                ForEach(model.sources) { source in
                    DisclosureGroup {
                        ForEach(source.categories) { category in
                            Toggle(isOn: Binding(
                                get: { source.enabledCategoryIDs.contains(category.id) },
                                set: { enabled in
                                    Task { await model.setCategory(category, in: source, enabled: enabled) }
                                }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(category.name)
                                    HStack {
                                        if let language = category.language {
                                            Text(language)
                                        }
                                        if let count = category.frames {
                                            if category.language == nil {
                                                Text("\(count) frames")
                                            } else {
                                                Text("· \(count) frames")
                                            }
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.isWorking)
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(source.name)
                                if source.isDefault {
                                    Text("Default")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: .capsule)
                                }
                            }
                            Text(source.sourceURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let error = source.refreshError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    if !source.isDefault {
                        Button("Remove \(source.name)", systemImage: "trash", role: .destructive) {
                            Task { await model.removeSource(source) }
                        }
                    }
                }
                Button("Add Source", systemImage: "plus") { showingAddSource = true }
                Button("Restore Default Sources", systemImage: "arrow.counterclockwise") {
                    Task { await model.restoreBundledSources() }
                }
                .disabled(model.isWorking)
            }

            Section("Synchronization") {
                Picker("Refresh", selection: $model.refreshFrequency) {
                    ForEach(RefreshFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                Button("Refresh Now", systemImage: "arrow.clockwise") {
                    Task { await model.refreshAll() }
                }
                .disabled(model.isWorking || model.sources.isEmpty)
            }
        }
        .sheet(isPresented: $showingAddSource) {
            AddSourceView(model: model)
        }
    }
}

#if DEBUG
#Preview("Source Settings") {
    Form {
        SourcesSettingsView(model: PreviewData.model())
    }
    .formStyle(.grouped)
}
#endif
