//
//  FrameShareLink.swift
//  Tshunhue
//
//  Shares one frame with an explicit JPEG preview for the system share sheet.
//

import SwiftUI

/// A standard frame-sharing control with a coalesced, data-only image preview.
struct FrameShareLink: View {
    /// The frame exported by the link.
    let frame: CatalogFrame
    /// The model that creates the shared transfer state.
    @ObservedObject var model: AppModel

    var body: some View {
        let item = model.transferItem(for: frame)
        ShareLink(
            item: item,
            preview: SharePreview(frame.frame.caption, image: item.previewImage)
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

#if DEBUG
#Preview("Frame Share Link") {
    FrameShareLink(frame: PreviewData.frame, model: PreviewData.model())
        .padding()
}
#endif
