//
//  FrameThumbnailView.swift
//  Tshunhue
//
//  Loads and presents a cached thumbnail for a catalog frame.
//

import SwiftUI

/// An asynchronous frame image with progress, error, and retry states.
struct FrameThumbnailView: View {
    /// The frame whose image should be loaded.
    let frame: CatalogFrame
    /// The repository that downloads and caches the image.
    let repository: ImageRepository
    /// Whether to request and style a larger preview image.
    var large = false

    @State private var thumbnail: ImageThumbnail?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if let error {
                VStack(spacing: 8) {
                    ContentUnavailableView(
                        "Image Unavailable",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(error)
                    )
                    Button("Retry", systemImage: "arrow.clockwise") {
                        self.error = nil
                        attempt += 1
                    }
                    .buttonStyle(.borderless)
                }
                .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: large ? 12 : 8))
        .task(id: "\(frame.imageURL.absoluteString)#\(attempt)") {
            do {
                thumbnail = try await repository.thumbnail(
                    for: frame.imageURL,
                    maxPixelSize: large ? 1_600 : 640
                )
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
        .accessibilityLabel(frame.frame.caption)
    }
}

#if DEBUG
#Preview("Frame Thumbnail") {
    let model = PreviewData.model()
    FrameThumbnailView(frame: PreviewData.frame, repository: model.imageRepository)
        .frame(width: 420)
        .padding()
}
#endif
