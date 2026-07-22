//
//  ContentView+macOS.swift
//  Tshunhue
//
//  Defines the macOS split-view browser, inspector, and Quick Look behavior.
//

#if os(macOS)
import QuickLook
import SwiftUI

/// The macOS split-view browser with an independent details inspector.
struct MacContentView: View {
    @ObservedObject var model: AppModel
    @Binding var groupFrames: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorPresented = true
    @State private var quickLookURL: URL?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CategorySidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            FrameGridView(
                model: model,
                frames: model.displayedFrames,
                scope: model.selectedScope,
                hasSearchQuery: model.hasSearchQuery,
                groupFrames: groupFrames,
                onPreview: showPreview
            )
                .navigationTitle(model.navigationTitle)
                .searchable(text: $model.query, prompt: "Search captions and tags")
                .searchFocused($searchFocused)
        }
        .inspector(isPresented: $inspectorPresented) {
            Group {
                if let frame = model.selectedFrame {
                    FrameDetailsView(frame: frame, model: model)
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 250, max: 320)
        }
        .toolbar {
            if let frame = model.selectedFrame {
                ToolbarItem(id: "copy") {
                    Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
                        .keyboardShortcut("c", modifiers: .command)
                }

                ToolbarItem(id: "share") {
                    FrameShareLink(frame: frame, model: model)
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
            NavigationStack {
                InitialCategoryPickerView(model: model) {
                    model.needsCategorySelection = false
                }
            }
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

#if DEBUG
#Preview("Content - macOS") {
    MacContentView(model: PreviewData.model(), groupFrames: .constant(false))
        .frame(width: 900, height: 620)
}
#endif
#endif
