//
//  ContentView.swift
//  Tshunhue
//
//  Created by 姜柏任 on 2026/7/21.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        #if os(macOS)
        MacContentView(model: model)
        #else
        IOSContentView(model: model)
        #endif
    }
}

#if os(macOS)
private struct MacContentView: View {
    @ObservedObject var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previewedFrame: CatalogFrame?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CategorySidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            FrameGridView(model: model, previewedFrame: $previewedFrame)
                .navigationTitle(model.query.isEmpty ? "Recent" : "Results")
                .searchable(text: $model.query, placement: .toolbar, prompt: "Search captions and tags")
                .searchFocused($searchFocused)
                .onKeyPress(.space) {
                    guard let frame = model.selectedFrame else { return .ignored }
                    previewedFrame = frame
                    return .handled
                }
        } detail: {
            if let frame = model.selectedFrame {
                FrameDetailsView(frame: frame, model: model)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshAll() }
                }
                .disabled(model.isWorking || model.sources.isEmpty)
                if let frame = model.selectedFrame {
                    Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
                        .keyboardShortcut("c", modifiers: .command)
                    ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption))
                }
                Button("Toggle Inspector", systemImage: "sidebar.right") {
                    columnVisibility = columnVisibility == .all ? .doubleColumn : .all
                }
            }
        }
        .overlay(alignment: .top) {
            if model.isWorking { ProgressView().padding(8) }
        }
        .sheet(item: $previewedFrame) { frame in
            FramePreviewView(frame: frame, model: model)
        }
        .sheet(isPresented: $model.needsCategorySelection) {
            InitialCategoryPickerView(model: model)
        }
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
}
#else
private struct IOSContentView: View {
    @ObservedObject var model: AppModel
    @State private var previewedFrame: CatalogFrame?
    @State private var detailFrame: CatalogFrame?
    @State private var showingFilters = false
    @State private var showingSettings = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            FrameGridView(
                model: model,
                previewedFrame: $previewedFrame,
                onShowDetails: { detailFrame = $0 }
            )
            .navigationTitle(model.query.isEmpty ? "Recent" : "Results")
            .searchable(text: $model.query, prompt: "Search captions and tags")
            .searchFocused($searchFocused)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                        showingFilters = true
                    }
                    Button("Settings", systemImage: "gear") { showingSettings = true }
                }
            }
            .navigationDestination(item: $detailFrame) { frame in
                FrameDetailsView(frame: frame, model: model)
            }
        }
        .sheet(item: $previewedFrame) { frame in
            FramePreviewView(frame: frame, model: model)
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
}
#endif
