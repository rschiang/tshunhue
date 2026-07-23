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

// MARK: - Preview Data

/// One generated preview image and its display-ready thumbnail.
private struct KeyboardPreviewImage: Sendable {
    let asset: ImageAsset
    let thumbnail: ImageThumbnail
}

/// A memory-only provider that keeps Canvas independent of App Groups and network access.
private actor KeyboardPreviewDataStore: KeyboardDataProviding {
    private let frames: [CatalogFrame]
    private let images: [URL: KeyboardPreviewImage]

    /// Creates a deterministic four-result preview data source.
    init(frames: [CatalogFrame], images: [URL: KeyboardPreviewImage]) {
        self.frames = frames
        self.images = images
    }

    /// Returns every category represented by the preview frames.
    func load(allowsImages: Bool) async throws -> KeyboardCatalogSnapshot {
        var seen: Set<CategoryKey> = []
        let categories = frames.compactMap { frame -> KeyboardCategoryOption? in
            guard seen.insert(frame.categoryKey).inserted else { return nil }
            return KeyboardCategoryOption(
                key: frame.categoryKey,
                name: frame.categoryName,
                sourceName: frame.sourceName
            )
        }
        return KeyboardCatalogSnapshot(categories: categories)
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

    /// Returns the generated local bitmap associated with a representative frame.
    func thumbnail(for frame: CatalogFrame, maxPixelSize: Int) async -> ImageThumbnail? {
        images[frame.imageURL]?.thumbnail
    }

    /// Returns generated JPEG bytes without touching a preview cache directory.
    func asset(for url: URL) async throws -> ImageAsset {
        guard let asset = images[url]?.asset else { throw KeyboardDataError.imagesUnavailable }
        return asset
    }

    /// Preview actions deliberately do not write shared recent history.
    func recordRecent(_ identity: FrameIdentity) async throws {}

    /// The fixture owns no mutable decoded cache.
    func releaseImages() async {}
}

// MARK: - Host Document

/// Models the host application's editable text and current selection for Canvas.
private struct KeyboardPreviewDocument {
    var text = ""
    var selection: TextSelection?

    /// Produces the same selected-text or caret context read by the extension controller.
    var query: String {
        let range = selectedRange
        let selectedText = range.flatMap { range in
            range.isEmpty ? nil : String(text[range])
        }
        let beforeInput = range.map { String(text[..<$0.lowerBound]) } ?? text
        let afterInput = range.map { String(text[$0.upperBound...]) }
        return KeyboardQueryContext.query(
            selectedText: selectedText,
            beforeInput: beforeInput,
            afterInput: afterInput
        )
    }

    /// Inserts text at the caret or replaces the current selection.
    mutating func insertText(_ insertedText: String) {
        replace(selectedRange ?? text.endIndex..<text.endIndex, with: insertedText)
    }

    /// Removes the selection or the character immediately before the caret.
    mutating func deleteBackward() {
        let range = selectedRange ?? text.endIndex..<text.endIndex
        if !range.isEmpty {
            replace(range, with: "")
        } else if range.lowerBound != text.startIndex {
            let previousIndex = text.index(before: range.lowerBound)
            replace(previousIndex..<range.lowerBound, with: "")
        }
    }

    /// The single range produced by an ordinary SwiftUI `TextField` selection.
    private var selectedRange: Range<String.Index>? {
        guard let indices = selection?.indices else { return nil }
        switch indices {
        case .selection(let range):
            return range
        case .multiSelection(let ranges):
            return ranges.ranges.first
        @unknown default:
            return nil
        }
    }

    /// Replaces a range and collapses the selection after the inserted text.
    private mutating func replace(_ range: Range<String.Index>, with replacement: String) {
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: replacement)
        let replacementStart = text.index(text.startIndex, offsetBy: offset)
        let insertionPoint = text.index(replacementStart, offsetBy: replacement.count)
        selection = TextSelection(insertionPoint: insertionPoint)
    }
}

// MARK: - Preview Container

/// Owns preview model lifetime and simulates a host document around the keyboard.
@MainActor
struct KeyboardPreviewContainer: View {
    @State private var model: KeyboardModel
    @State private var document = KeyboardPreviewDocument()
    private let mode: KeyboardAccessMode

    /// Creates one preview state with local images and four catalog frames.
    init(mode: KeyboardAccessMode) {
        let frames = Self.makeFrames()
        let store = KeyboardPreviewDataStore(
            frames: frames,
            images: Self.makeImages(for: frames)
        )
        self.mode = mode
        _model = State(initialValue: KeyboardModel(
            dataProvider: store,
            allowsDragging: false,
            searchDelayNanoseconds: 0
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                "Host application text",
                text: $document.text,
                selection: $document.selection
            )
            .textFieldStyle(.roundedBorder)
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            KeyboardView(
                model: model,
                inputModeController: { nil },
                insertCaption: insertCaption,
                insertSpace: { insertText(" ") },
                deleteBackward: deleteBackward
            )
        }
        .onChange(of: document.text) { refreshQuery() }
        .onChange(of: document.selection) { refreshQuery() }
        .task {
            refreshQuery()
            await model.activate(mode: mode, needsInputModeSwitchKey: false)
        }
    }

    /// Inserts a caption into the simulated host document and publishes feedback.
    private func insertCaption(_ frame: CatalogFrame) {
        document.insertText(frame.frame.caption)
        model.didInsertCaption(frame)
        refreshQuery()
    }

    /// Inserts text using the simulated host document selection.
    private func insertText(_ text: String) {
        document.insertText(text)
        refreshQuery()
    }

    /// Deletes backward using the simulated host document selection.
    private func deleteBackward() {
        document.deleteBackward()
        refreshQuery()
    }

    /// Refreshes the model from the simulated host selection and caret context.
    private func refreshQuery() {
        model.updateQuery(document.query)
    }

    // MARK: - Fixtures

    /// Splits the shared four-frame fixture across two filterable categories.
    private static func makeFrames() -> [CatalogFrame] {
        PreviewData.frames.enumerated().map { index, frame in
            guard index >= 2 else { return frame }
            let categoryID = "everyday-reactions"
            return CatalogFrame(
                identity: FrameIdentity(
                    sourceURL: frame.identity.sourceURL,
                    categoryID: categoryID,
                    frameID: frame.identity.frameID
                ),
                sourceName: frame.sourceName,
                categoryID: categoryID,
                categoryName: "Everyday Reactions",
                language: frame.language,
                subsection: frame.subsection,
                frame: frame.frame,
                effectiveID: frame.effectiveID,
                imageURL: frame.imageURL,
                providers: frame.providers,
                attribution: frame.attribution,
                reportURL: frame.reportURL,
                categoryOrder: 1,
                subsectionOrder: frame.subsectionOrder,
                order: frame.order
            )
        }
    }

    /// Generates distinct local JPEGs so image results are visually identifiable.
    private static func makeImages(for frames: [CatalogFrame]) -> [URL: KeyboardPreviewImage] {
        let colors: [UIColor] = [.systemIndigo, .systemPink, .systemTeal, .systemOrange]
        let symbols = ["camera.macro", "quote.bubble.fill", "sparkles", "photo.stack.fill"]
        let size = CGSize(width: 640, height: 360)

        return Dictionary(uniqueKeysWithValues: frames.enumerated().map { index, frame in
            let image = UIGraphicsImageRenderer(size: size).image { context in
                colors[index % colors.count].setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: size))
                UIImage(systemName: symbols[index % symbols.count])?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 250, y: 110, width: 140, height: 140))
            }
            let data = image.jpegData(compressionQuality: 0.8)!
            let cgImage = image.cgImage!
            let asset = ImageAsset(
                data: data,
                type: .jpeg,
                width: cgImage.width,
                height: cgImage.height,
                localURL: URL(fileURLWithPath: "/KeyboardPreview-\(index).jpg")
            )
            return (frame.imageURL, KeyboardPreviewImage(
                asset: asset,
                thumbnail: ImageThumbnail(image: cgImage)
            ))
        })
    }
}

#endif
