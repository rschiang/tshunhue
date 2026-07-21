//
//  FrameGridView.swift
//  Tshunhue
//
//  Presents searchable frame results in flat or grouped image grids.
//

import SwiftUI

/// The primary reaction-image grid and its contextual transfer actions.
struct FrameGridView: View {
    /// The model providing visible frames and selection state.
    @ObservedObject var model: AppModel
    /// Whether frames should be divided into category or subsection sections.
    let groupFrames: Bool
    /// An optional selection callback used to navigate to iOS details.
    var onShowDetails: ((CatalogFrame) -> Void)?
    /// An optional callback for the platform's full preview experience.
    var onPreview: ((CatalogFrame) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 360), spacing: 16)]
    #if os(macOS)
    @FocusState private var gridFocused: Bool
    #endif

    var body: some View {
        Group {
            if model.displayedFrames.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        if groupFrames {
                            ForEach(model.frameSections) { section in
                                Section {
                                    ForEach(section.frames) { frame in
                                        frameCell(frame)
                                    }
                                } header: {
                                    sectionHeader(section)
                                }
                            }
                        } else {
                            ForEach(model.displayedFrames) { frame in
                                frameCell(frame)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .accessibilityIdentifier("frame-grid")
        #if os(macOS)
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let frame = model.selectedFrame, let onPreview else { return .ignored }
            onPreview(frame)
            return .handled
        }
        #endif
    }

    /// The appropriate empty-search or empty-catalog message.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                emptyTitle,
                systemImage: model.hasSearchQuery ? "magnifyingglass" : "sparkles.rectangle.stack"
            )
        } description: {
            Text(emptyDescription)
        }
    }

    /// The title for the current empty-grid condition.
    private var emptyTitle: LocalizedStringKey {
        if model.hasSearchQuery { return "No Results" }
        if model.isShowingRecents { return "No Recent Images" }
        return "No Images"
    }

    /// Supporting guidance for the current empty-grid condition.
    private var emptyDescription: LocalizedStringKey {
        if model.hasSearchQuery { return "Try fewer words or choose another index or category." }
        if model.isShowingRecents { return "Images you copy, share, or drag will appear here." }
        return "Add a source and enable categories in Settings."
    }

    /// Builds a category or subsection heading for grouped results.
    private func sectionHeader(_ section: FrameSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.title3.bold())
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    /// Builds one selectable, draggable frame cell and its context menu.
    private func frameCell(_ frame: CatalogFrame) -> some View {
        Button {
            model.selectedFrameID = frame.identity
            #if os(macOS)
            gridFocused = true
            #endif
            onShowDetails?(frame)
        } label: {
            FrameThumbnailView(frame: frame, repository: model.imageRepository)
            .overlay {
                if model.selectedFrameID == frame.identity {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.tint, lineWidth: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onPreview {
                Button("Preview", systemImage: "eye") { onPreview(frame) }
            }
            Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
            ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if model.isShowingRecents {
                Divider()
                Button("Remove from Recents", systemImage: "clock.badge.xmark") {
                    Task { await model.removeRecent(frame) }
                }
            }
        } preview: {
            FrameThumbnailView(frame: frame, repository: model.imageRepository, large: true)
        }
        .draggable(model.transferItem(for: frame))
    }
}

#if DEBUG
#Preview("Frame Grid") {
    FrameGridView(
        model: PreviewData.model(),
        groupFrames: false
    )
    .frame(idealWidth: 700, idealHeight: 520)
}
#endif
