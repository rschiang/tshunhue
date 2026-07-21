//
//  FramePreviewView.swift
//  Tshunhue
//
//  Presents a focused frame preview with copy and share actions.
//

import SwiftUI

/// A modal, enlarged reaction-image preview.
struct FramePreviewView: View {
    /// The frame being previewed.
    let frame: CatalogFrame
    /// The model used to perform outbound transfers.
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            FrameThumbnailView(frame: frame, repository: model.imageRepository, large: true)
            Text(frame.frame.caption)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack {
                Button("Copy", systemImage: "doc.on.doc") { Task { await model.copy(frame) } }
                    .keyboardShortcut("c", modifiers: .command)
                ShareLink(item: model.transferItem(for: frame), preview: SharePreview(frame.frame.caption))
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 320)
    }
}

#if DEBUG
#Preview("Frame Preview") {
    FramePreviewView(frame: PreviewData.frame, model: PreviewData.model())
}
#endif
