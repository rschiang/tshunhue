import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showingAddSource = false
    @State private var showingPrivacy = false
    @State private var showingAbout = false

    var body: some View {
        Form {
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

            Section("Storage") {
                LabeledContent("Image Cache", value: formattedCacheSize)
                Button("Clear Image Cache", systemImage: "trash") {
                    Task { await model.clearCache() }
                }
                Button("Clear Recent Items", systemImage: "clock.badge.xmark") {
                    Task { await model.clearRecents() }
                }
            }

            Section("Privacy") {
                Text("Tshunhue has no accounts, analytics, or telemetry. Source and image hosts receive ordinary network requests when content is synchronized or displayed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Privacy Policy", systemImage: "hand.raised") { showingPrivacy = true }
                Button("About Tshunhue", systemImage: "info.circle") { showingAbout = true }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingAddSource) {
            AddSourceView(model: model)
        }
        .sheet(isPresented: $showingPrivacy) {
            PolicyView()
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .task { await model.refreshCacheSize() }
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(model.cacheByteCount), countStyle: .file)
    }
}

private struct PolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("Tshunhue has no accounts, analytics, advertising, or telemetry. Catalogs and images are requested directly from the HTTPS hosts you configure, so those hosts receive ordinary network information such as your IP address. Search history and recent transfers remain on this device. Tshunhue does not inspect or transmit text typed with its keyboard extension.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Privacy Policy")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "camera.macro")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Tshunhue").font(.title.bold())
                Text("Spring flowers — a community meme image browser.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Version \(version)").font(.caption)
            }
            .padding(32)
            .navigationTitle("About Tshunhue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}

private struct AddSourceView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("https://example.com/index.json", text: $sourceURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Text("Tshunhue validates default and custom sources using the same rules. Images download only when displayed or transferred.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Add Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            if await model.addSource(urlString: sourceURL) { dismiss() }
                        }
                    }
                    .disabled(sourceURL.isEmpty || model.isWorking)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 240)
    }
}
