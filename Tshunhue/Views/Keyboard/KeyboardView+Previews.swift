//
//  KeyboardView+Previews.swift
//  Tshunhue
//
//  Hosts isolated keyboard previews in the containing app rather than the extension.
//

#if DEBUG && os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A memory-only provider that keeps Canvas independent of App Groups and network access.
private actor KeyboardPreviewDataStore: KeyboardDataProviding {
    private let frames: [CatalogFrame]
    private let assetValue: ImageAsset
    private let thumbnailValue: ImageThumbnail

    /// Creates a deterministic four-result preview data source.
    init(frames: [CatalogFrame], asset: ImageAsset, thumbnail: ImageThumbnail) {
        self.frames = frames
        assetValue = asset
        thumbnailValue = thumbnail
    }

    /// Returns the single category represented by `PreviewData`.
    func load(allowsImages: Bool) async throws -> KeyboardCatalogSnapshot {
        guard let first = frames.first else { return KeyboardCatalogSnapshot(categories: []) }
        return KeyboardCatalogSnapshot(categories: [
            KeyboardCategoryOption(
                key: first.categoryKey,
                name: first.categoryName,
                sourceName: first.sourceName
            ),
        ])
    }

    /// Filters the in-memory fixture while preserving its deterministic order.
    func results(for query: String, category: CategoryKey?, limit: Int) async -> [CatalogFrame] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = frames.filter { frame in
            let categoryMatches = category == nil || frame.categoryKey == category
            let queryMatches = trimmed.isEmpty
                || frame.frame.caption.localizedCaseInsensitiveContains(trimmed)
                || frame.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
            return categoryMatches && queryMatches
        }
        return Array(matching.prefix(limit))
    }

    /// Returns the generated local bitmap for every representative frame.
    func thumbnail(for frame: CatalogFrame, maxPixelSize: Int) async -> ImageThumbnail? {
        thumbnailValue
    }

    /// Returns generated JPEG bytes without touching a preview cache directory.
    func asset(for url: URL) async throws -> ImageAsset { assetValue }

    /// Preview actions deliberately do not write shared recent history.
    func recordRecent(_ identity: FrameIdentity) async throws {}

    /// The fixture owns no mutable decoded cache.
    func releaseImages() async {}
}

/// Owns preview model lifetime and supplies harmless stand-ins for host keyboard actions.
@MainActor
struct KeyboardPreviewContainer: View {
    @State private var model: KeyboardModel
    private let mode: KeyboardAccessMode

    /// Creates one preview state with generated image bytes and four catalog frames.
    init(mode: KeyboardAccessMode, query: String = "") {
        let fixture = Self.makeImageFixture()
        let store = KeyboardPreviewDataStore(
            frames: PreviewData.frames,
            asset: fixture.asset,
            thumbnail: fixture.thumbnail
        )
        self.mode = mode
        _model = State(initialValue: KeyboardModel(
            dataProvider: store,
            allowsDragging: false,
            searchDelayNanoseconds: 0
        ))
        initialQuery = query
    }

    /// The host-derived query applied once when Canvas starts the model.
    private let initialQuery: String

    var body: some View {
        KeyboardView(
            model: model,
            inputModeController: { nil },
            insertCaption: { frame in model.didInsertCaption(frame) },
            insertSpace: { model.updateQuery(model.query + " ") },
            deleteBackward: { model.updateQuery(String(model.query.dropLast())) }
        )
        .task {
            model.updateQuery(initialQuery)
            await model.activate(mode: mode, needsInputModeSwitchKey: true)
        }
    }

    /// Generates a colorful local JPEG and matching Core Graphics thumbnail in memory.
    private static func makeImageFixture() -> (asset: ImageAsset, thumbnail: ImageThumbnail) {
        let size = CGSize(width: 640, height: 360)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIImage(systemName: "camera.macro")?.withTintColor(.white).draw(
                in: CGRect(x: 250, y: 110, width: 140, height: 140)
            )
        }
        let data = image.jpegData(compressionQuality: 0.8)!
        let cgImage = image.cgImage!
        return (
            ImageAsset(
                data: data,
                type: .jpeg,
                width: cgImage.width,
                height: cgImage.height,
                localURL: URL(fileURLWithPath: "/KeyboardPreview.jpg")
            ),
            ImageThumbnail(image: cgImage)
        )
    }
}

#endif
