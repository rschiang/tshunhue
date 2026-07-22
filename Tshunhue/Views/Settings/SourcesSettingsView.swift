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
    #if os(macOS)
    @State private var showingAddSource = false
    #endif

    var body: some View {
        Group {
            Section("Sources") {
                if model.sources.isEmpty {
                    ContentUnavailableView(
                        "No Sources",
                        systemImage: "tray",
                        description: Text("Add a source index to begin.")
                    )
                }
                ForEach(model.sources) { source in
                    DisclosureGroup {
                        CategorySelectionRows(model: model, source: source)
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
                        .disabled(model.isWorking || model.isUpdatingCategories(in: source))
                    }
                }
                #if os(macOS)
                Button("Add Source", systemImage: "plus") { showingAddSource = true }
                #else
                NavigationLink(value: SettingsRoute.addSource) {
                    Label("Add Source", systemImage: "plus")
                }
                #endif
                Button("Restore Default Sources", systemImage: "arrow.counterclockwise") {
                    Task { await model.restoreBundledSources() }
                }
                .disabled(model.isWorking || model.hasPendingCategoryUpdates)
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
                .disabled(model.isWorking || model.hasPendingCategoryUpdates || model.sources.isEmpty)
            }
        }
        #if os(macOS)
        .sheet(isPresented: $showingAddSource) {
            NavigationStack {
                AddSourceView(model: model)
            }
        }
        #endif
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
