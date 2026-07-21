import SwiftUI

struct FrameThumbnailView: View {
    let frame: CatalogFrame
    let repository: ImageRepository
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
