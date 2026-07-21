//
//  ContentView.swift
//  Tshunhue
//
//  Composes the platform-specific browsing interface and shared presentation state.
//

import SwiftUI
#if os(macOS)
import QuickLook
#endif

/// The adaptive root view for Tshunhue's macOS and iOS experiences.
struct ContentView: View {
    /// The shared application state and command model.
    @ObservedObject var model: AppModel
    @AppStorage("groupFrames") private var groupFrames = false

    var body: some View {
        #if os(macOS)
        MacContentView(model: model, groupFrames: $groupFrames)
        #else
        IOSContentView(model: model, groupFrames: $groupFrames)
        #endif
    }
}

#if os(macOS)
/// The macOS split-view browser with an independent details inspector.
private struct MacContentView: View {
    @ObservedObject var model: AppModel
    @Binding var groupFrames: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorPresented = true
    @State private var quickLookURL: URL?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CategorySidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            FrameGridView(model: model, groupFrames: groupFrames, onPreview: showPreview)
                .navigationTitle(model.navigationTitle)
                .searchable(text: $model.query, placement: .toolbar, prompt: "Search captions and tags")
                .searchFocused($searchFocused)
        }
        .inspector(isPresented: $inspectorPresented) {
            Group {
                if let frame = model.selectedFrame {
                    FrameDetailsView(frame: frame, model: model)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.right")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
        }
        .toolbar {
            if let frame = model.selectedFrame {
                ToolbarItem(id: "copy") {
                    Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
                        .keyboardShortcut("c", modifiers: .command)
                }
                
                ToolbarItem(id: "share") {
                    ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption))
                }
            }
            ToolbarItemGroup {
                Button(groupingLabel, systemImage: groupFrames ? "rectangle.3.group.fill" : "rectangle.3.group") {
                    groupFrames.toggle()
                }
                .help(groupingLabel)
                .accessibilityValue(groupFrames ? "On" : "Off")

                Button("Toggle Inspector", systemImage: "sidebar.right") {
                    inspectorPresented.toggle()
                }
                .help(inspectorPresented ? "Hide Inspector" : "Show Inspector")
            }
        }
        .overlay(alignment: .top) {
            if model.isWorking { ProgressView().padding(8) }
        }
        .sheet(isPresented: $model.needsCategorySelection) {
            InitialCategoryPickerView(model: model)
        }
        .quickLookPreview($quickLookURL)
        .onAppear { searchFocused = true }
        .alert("Tshunhue", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var groupingLabel: LocalizedStringKey {
        model.groupsBySubsection ? "Group by Subsection" : "Group by Category"
    }

    /// Downloads an image if needed, then presents its cached file with Quick Look.
    private func showPreview(_ frame: CatalogFrame) {
        Task {
            do {
                let asset = try await model.imageRepository.asset(for: frame.imageURL)
                quickLookURL = asset.localURL
            } catch is CancellationError {
                return
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
#else
/// The iOS navigation-based browser and modal settings experience.
private struct IOSContentView: View {
    @ObservedObject var model: AppModel
    @Binding var groupFrames: Bool
    @State private var detailFrame: CatalogFrame?
    @State private var showingFilters = false
    @State private var showingSettings = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            FrameGridView(
                model: model,
                groupFrames: groupFrames,
                onShowDetails: { detailFrame = $0 },
                onPreview: { detailFrame = $0 }
            )
            .navigationTitle(model.navigationTitle)
            .searchable(text: $model.query, prompt: "Search captions and tags")
            .searchFocused($searchFocused)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                        showingFilters = true
                    }
                    Button(groupingLabel, systemImage: groupFrames ? "rectangle.3.group.fill" : "rectangle.3.group") {
                        groupFrames.toggle()
                    }
                    .accessibilityValue(groupFrames ? "On" : "Off")
                    Button("Settings", systemImage: "gear") { showingSettings = true }
                }
            }
            .navigationDestination(item: $detailFrame) { frame in
                FrameDetailsView(frame: frame, model: model)
            }
        }
        .sheet(isPresented: $showingFilters) {
            NavigationStack {
                CategorySidebarView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingFilters = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $model.needsCategorySelection) {
            InitialCategoryPickerView(model: model)
        }
        .onAppear { searchFocused = true }
        .overlay(alignment: .top) {
            if model.isWorking { ProgressView().padding(8) }
        }
        .alert("Tshunhue", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }


    private var groupingLabel: LocalizedStringKey {
        model.groupsBySubsection ? "Group by Subsection" : "Group by Category"
    }
}
#endif

#if DEBUG
#Preview("Content") { ContentView(model: PreviewData.model()) }
#endif
