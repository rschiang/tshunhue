import SwiftUI

struct FrameGridView: View {
    @ObservedObject var model: AppModel
    @Binding var previewedFrame: CatalogFrame?
    var onShowDetails: ((CatalogFrame) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 420), spacing: 16)]

    var body: some View {
        Group {
            if model.displayedFrames.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.displayedFrames) { frame in
                            frameCell(frame)
                        }
                    }
                    .padding()
                }
            }
        }
        .accessibilityIdentifier("frame-grid")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                model.query.isEmpty ? "Find the perfect reaction" : "No Results",
                systemImage: model.query.isEmpty ? "sparkles.rectangle.stack" : "magnifyingglass"
            )
        } description: {
            Text(model.query.isEmpty
                 ? "Add a source and enable categories in Settings, then start typing to search."
                 : "Try fewer words or enable another category.")
        }
    }

    private func frameCell(_ frame: CatalogFrame) -> some View {
        Button {
            model.selectedFrameID = frame.identity
            onShowDetails?(frame)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                FrameThumbnailView(frame: frame, repository: model.imageRepository)
                    .overlay {
                        if model.selectedFrameID == frame.identity {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.tint, lineWidth: 3)
                        }
                    }
                Text(frame.frame.caption)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack {
                    Text(frame.categoryName)
                    if let subsection = frame.subsection {
                        Text("·")
                        Text(subsection.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Preview", systemImage: "eye") { previewedFrame = frame }
            Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
            ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if model.query.isEmpty {
                Divider()
                Button("Remove from Recents", systemImage: "clock.badge.xmark") {
                    Task { await model.removeRecent(frame) }
                }
            }
        } preview: {
            FramePreviewView(frame: frame, model: model)
                .frame(idealWidth: 640, idealHeight: 480)
        }
        .draggable(model.transferItem(for: frame)) {
            FrameThumbnailView(frame: frame, repository: model.imageRepository)
                .frame(width: 240)
        }
    }
}
