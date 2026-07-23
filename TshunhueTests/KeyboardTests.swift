//
//  KeyboardTests.swift
//  TshunhueTests
//
//  Verifies host-query extraction and the reusable keyboard model's bounded behavior.
//

import Foundation
import Testing
@testable import Tshunhue

/// Tests query derivation without requiring a keyboard extension host.
struct KeyboardQueryContextTests {
    @Test func selectedTextTakesPriority() {
        let query = KeyboardQueryContext.query(
            selectedText: "  selected reaction  ",
            beforeInput: "ignored",
            afterInput: " context"
        )
        #expect(query == "selected reaction")
    }

    @Test func currentLineJoinsBothSidesOfCaret() {
        let query = KeyboardQueryContext.query(
            selectedText: nil,
            beforeInput: "previous line\n春天",
            afterInput: "來矣\nnext line"
        )
        #expect(query == "春天來矣")
    }

    @Test func unavailableOrBlankContextProducesEmptyQuery() {
        #expect(KeyboardQueryContext.query(
            selectedText: " \n ",
            beforeInput: nil,
            afterInput: nil
        ).isEmpty)
    }
}

/// Tests the reusable Observation model with an actor-backed in-memory provider.
@MainActor
struct KeyboardModelTests {
    @Test func activationShowsAtMostFourRecentsAndNeutralTextMode() async {
        let frames = Self.makeFrames()
        let store = KeyboardTestDataStore(frames: frames, recents: Array(frames.reversed()))
        let model = KeyboardModel(
            dataProvider: store,
            searchDelayNanoseconds: 0
        )

        await model.activate(mode: .text, needsInputModeSwitchKey: true)

        #expect(model.accessMode == .text)
        #expect(model.needsInputModeSwitchKey)
        #expect(model.results.count == KeyboardModel.resultLimit)
        #expect(model.results.map(\.effectiveID) == ["5", "4", "3", "2"])
        #expect(model.transferItem(for: frames[0]) == nil)
    }

    @Test func queryAndCategoryChangesReplaceObsoleteResults() async {
        let frames = Self.makeFrames()
        let store = KeyboardTestDataStore(frames: frames, recents: [])
        let model = KeyboardModel(
            dataProvider: store,
            searchDelayNanoseconds: 0
        )
        await model.activate(mode: .images, needsInputModeSwitchKey: false)

        model.updateQuery("match")
        #expect(await eventually { model.results.map(\.effectiveID) == ["1", "2", "3", "4"] })

        let secondCategory = frames[4].categoryKey
        model.selectCategory(secondCategory)
        #expect(await eventually { model.results.map(\.effectiveID) == ["5"] })
        #expect(model.transferItem(for: frames[4]) != nil)
    }

    /// Builds five frames so the result cap and category filter are both observable.
    private static func makeFrames() -> [CatalogFrame] {
        (1...5).map { number in
            let sourceURL = URL(string: "https://example.com/index.json")!
            let categoryID = number == 5 ? "second" : "first"
            let imageURL = URL(string: "https://example.com/\(number).jpg")!
            return CatalogFrame(
                identity: FrameIdentity(
                    sourceURL: sourceURL,
                    categoryID: categoryID,
                    frameID: String(number)
                ),
                sourceName: "Example",
                categoryID: categoryID,
                categoryName: number == 5 ? "Second" : "First",
                language: "en",
                subsection: nil,
                frame: Frame(
                    id: String(number),
                    url: imageURL.absoluteString,
                    caption: "match \(number)",
                    tags: nil,
                    subsection: nil,
                    timecode: nil
                ),
                effectiveID: String(number),
                imageURL: imageURL,
                providers: [],
                attribution: nil,
                reportURL: nil,
                categoryOrder: number == 5 ? 1 : 0,
                subsectionOrder: nil,
                order: number - 1
            )
        }
    }

    /// Waits briefly for a zero-delay model search task to publish actor results.
    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

/// A deterministic provider used to test the model without disk, network, or pasteboards.
private actor KeyboardTestDataStore: KeyboardDataProviding {
    private let frames: [CatalogFrame]
    private let recents: [CatalogFrame]

    /// Creates a provider with explicit catalog and recent order.
    init(frames: [CatalogFrame], recents: [CatalogFrame]) {
        self.frames = frames
        self.recents = recents
    }

    /// Publishes one option for each distinct category.
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

    /// Applies the same recent, query, category, and limit semantics as production storage.
    func results(for query: String, category: CategoryKey?, limit: Int) async -> [CatalogFrame] {
        let candidates = query.isEmpty
            ? recents
            : frames.filter { $0.frame.caption.localizedCaseInsensitiveContains(query) }
        return Array(candidates.filter { category == nil || $0.categoryKey == category }.prefix(limit))
    }

    /// Model tests do not exercise decoded image delivery.
    func thumbnail(for frame: CatalogFrame, maxPixelSize: Int) async -> ImageThumbnail? { nil }

    /// Model tests do not exercise pasteboard delivery.
    func asset(for url: URL) async throws -> ImageAsset { throw KeyboardDataError.imagesUnavailable }

    /// Test recents need no persistence.
    func recordRecent(_ identity: FrameIdentity) async throws {}

    /// Test fixtures retain no decoded images.
    func releaseImages() async {}
}
