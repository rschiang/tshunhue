//
//  CatalogTests.swift
//  TshunhueTests
//
//  Verifies catalog validation, browsing, persistence, search, sync, and image transfer behavior.
//

import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Tshunhue

// MARK: - Catalog Validation

/// Tests schema semantics, timecodes, URL policy, and resolved frame metadata.
struct CatalogTests {
    private let validator = CatalogValidator()
    private let sourceURL = URL(string: "https://example.com/catalog/index.json")!

    @Test("All documented timecode forms normalize to milliseconds", arguments: [
        ("01:30", Int64(90_000)),
        ("01:30.5", Int64(90_500)),
        ("01:02:03.045", Int64(3_723_045)),
        ("01:02:03,045", Int64(3_723_045)),
    ])
    func timecodeStrings(value: String, expected: Int64) throws {
        #expect(try Timecode(parsing: value).milliseconds == expected)
    }

    @Test func numericTimecode() throws {
        let value = try JSONDecoder().decode(Timecode.self, from: Data("12.345".utf8))
        #expect(value.milliseconds == 12_345)
        #expect(value.displayString == "00:12.345")
    }

    @Test func invalidTimecodes() {
        #expect(throws: TimecodeError.self) { try Timecode(parsing: "1:60") }
        #expect(throws: TimecodeError.self) { try Timecode(parsing: "-1:00") }
        #expect(throws: TimecodeError.self) { try Timecode(parsing: "1:2") }
        #expect(throws: TimecodeError.self) { try Timecode(parsing: "1:02:60") }
        #expect(throws: TimecodeError.self) { try Timecode(seconds: -1) }
    }

    @Test func validatesAndResolvesCatalog() throws {
        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"show-zh","name":"Show","language":"zh-Hant-TW","url":"show.json"}]}"#.utf8)
        let index = try validator.validateIndex(data: indexData, sourceURL: sourceURL)
        #expect(index.categories[0].url == URL(string: "https://example.com/catalog/show.json"))

        let categoryData = Data(#"{"version":1,"id":"show-zh","name":"Show","language":"zh-Hant-TW","subsections":[{"id":"ep-1","name":"Episode 1"}],"frames":[{"url":"images/a.jpg","caption":"春天來矣","tags":["春天"],"subsection":"ep-1","timecode":"01:23"}]}"#.utf8)
        let category = try validator.validateCategory(
            data: categoryData,
            documentURL: index.categories[0].url,
            descriptor: index.categories[0].descriptor,
            source: index
        )
        #expect(category.frames.count == 1)
        #expect(category.frames[0].imageURL == URL(string: "https://example.com/catalog/images/a.jpg"))
        #expect(category.frames[0].subsection?.name == "Episode 1")
    }

    @Test func frameURLDoesNotAffectDerivedIdentity() throws {
        let first = Frame(id: nil, url: "a.jpg", caption: "Same", tags: nil, subsection: "ep", timecode: try Timecode(parsing: "01:00"))
        let second = Frame(id: nil, url: "compressed.jpg", caption: "Same", tags: ["new"], subsection: "ep", timecode: try Timecode(parsing: "01:00"))
        #expect(validator.derivedFrameID(categoryID: "show", frame: first) == validator.derivedFrameID(categoryID: "show", frame: second))
    }

    @Test func duplicateDerivedIdentityIsRejected() throws {
        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","language":"ja","url":"show.json"}]}"#.utf8)
        let index = try validator.validateIndex(data: indexData, sourceURL: sourceURL)
        let categoryData = Data(#"{"version":1,"id":"show","name":"Show","language":"ja","frames":[{"url":"a.jpg","caption":"same"},{"url":"b.jpg","caption":"same"}]}"#.utf8)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateCategory(
                data: categoryData,
                documentURL: index.categories[0].url,
                descriptor: index.categories[0].descriptor,
                source: index
            )
        }
    }

    @Test func externalLinksMustBeHTTPS() {
        let data = Data(#"{"version":1,"name":"Example","homepage":"http://example.com","categories":[]}"#.utf8)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateIndex(data: data, sourceURL: sourceURL)
        }
    }

    @Test func providerFallbackAndInterpolation() throws {
        let indexData = Data(#"{"version":1,"name":"Example","futureField":true,"categories":[{"id":"show","name":"Show","language":"nan-TW","url":"show.json","futureField":"ignored"}]}"#.utf8)
        let index = try validator.validateIndex(data: indexData, sourceURL: sourceURL)
        let categoryData = Data(#"{"version":1,"id":"show","name":"Show","language":"nan-TW","providers":[{"name":"Main","url":"https://video.example/show"}],"subsections":[{"id":"ep1","name":"Episode 1","providers":[{"name":"Episode","url":"https://video.example/ep1?t={seconds}&ms={milliseconds}"}]}],"frames":[{"id":"explicit","url":"a.png","caption":"春花","subsection":"ep1","timecode":"00:01.250"},{"url":"b.png","caption":"無段落"},{"url":"c.png","caption":"無時間碼","subsection":"ep1"}]}"#.utf8)
        let category = try validator.validateCategory(
            data: categoryData,
            documentURL: index.categories[0].url,
            descriptor: index.categories[0].descriptor,
            source: index
        )

        #expect(category.frames[0].effectiveID == "explicit")
        #expect(category.frames[0].providers.map(\.name) == ["Episode"])
        #expect(category.frames[0].providers[0].destination(for: category.frames[0].frame.timecode)?.absoluteString == "https://video.example/ep1?t=1&ms=1250")
        #expect(category.frames[1].providers.map(\.name) == ["Main"])
        #expect(category.frames[2].providers[0].destination(for: nil)?.absoluteString == "https://video.example/ep1?t=0&ms=0")
    }

    @Test func descriptorLanguageIsOptionalButMustMatchWhenPresent() throws {
        let withoutLanguage = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","url":"show.json"}]}"#.utf8)
        let optionalIndex = try validator.validateIndex(data: withoutLanguage, sourceURL: sourceURL)
        let categoryData = Data(#"{"version":1,"id":"show","name":"Show","language":"ja","frames":[]}"#.utf8)
        _ = try validator.validateCategory(
            data: categoryData,
            documentURL: optionalIndex.categories[0].url,
            descriptor: optionalIndex.categories[0].descriptor,
            source: optionalIndex
        )

        let mismatchedLanguage = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","language":"zh-Hant-TW","url":"show.json"}]}"#.utf8)
        let mismatchedIndex = try validator.validateIndex(data: mismatchedLanguage, sourceURL: sourceURL)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateCategory(
                data: categoryData,
                documentURL: mismatchedIndex.categories[0].url,
                descriptor: mismatchedIndex.categories[0].descriptor,
                source: mismatchedIndex
            )
        }
    }

    @Test func providerURLsRejectUnsafeOrUnknownPlaceholders() throws {
        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","url":"show.json"}]}"#.utf8)
        let index = try validator.validateIndex(data: indexData, sourceURL: sourceURL)
        for providerURL in [
            "http://video.example/watch",
            "https://video.example/{unknown}",
            "https://video.example/{seconds",
            "https://user:password@video.example/watch?t={seconds}",
        ] {
            let category = Category(
                version: 1,
                id: "show",
                name: "Show",
                language: "ja",
                attribution: nil,
                providers: [Provider(name: "Watch", url: providerURL)],
                subsections: nil,
                frames: []
            )
            #expect(throws: CatalogValidationError.self) {
                try validator.validateCategory(
                    data: JSONEncoder().encode(category),
                    documentURL: index.categories[0].url,
                    descriptor: index.categories[0].descriptor,
                    source: index
                )
            }
        }
    }

    @Test func applicationFrameLimitUsesUInt16Boundary() throws {
        #expect(CatalogLimits.framesPerCategory == 65_535)

        let maximumHint = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","url":"show.json","frames":65535}]}"#.utf8)
        _ = try validator.validateIndex(data: maximumHint, sourceURL: sourceURL)
        let excessiveHint = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","url":"show.json","frames":65536}]}"#.utf8)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateIndex(data: excessiveHint, sourceURL: sourceURL)
        }

        let index = try validator.validateIndex(data: maximumHint, sourceURL: sourceURL)
        let frames = (0..<CatalogLimits.framesPerCategory).map { number in
            Frame(
                id: "f\(number)",
                url: "image.png",
                caption: "Frame \(number)",
                tags: nil,
                subsection: nil,
                timecode: nil
            )
        }
        let category = Category(
            version: 1,
            id: "show",
            name: "Show",
            language: "ja",
            attribution: nil,
            providers: nil,
            subsections: nil,
            frames: frames
        )
        let accepted = try validator.validateCategory(
            data: JSONEncoder().encode(category),
            documentURL: index.categories[0].url,
            descriptor: index.categories[0].descriptor,
            source: index
        )
        #expect(accepted.frames.count == 65_535)

        let excessiveCategory = Category(
            version: category.version,
            id: category.id,
            name: category.name,
            language: category.language,
            attribution: category.attribution,
            providers: category.providers,
            subsections: category.subsections,
            frames: frames + [Frame(id: "overflow", url: "image.png", caption: "Overflow", tags: nil, subsection: nil, timecode: nil)]
        )
        #expect(throws: CatalogValidationError.self) {
            try validator.validateCategory(
                data: JSONEncoder().encode(excessiveCategory),
                documentURL: index.categories[0].url,
                descriptor: index.categories[0].descriptor,
                source: index
            )
        }
    }

    @Test func rejectsStructuralAndSafetyViolations() throws {
        let unsupported = Data(#"{"version":2,"name":"Example","categories":[]}"#.utf8)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateIndex(data: unsupported, sourceURL: sourceURL)
        }

        let invalidLanguage = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","language":"not_a_language","url":"show.json"}]}"#.utf8)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateIndex(data: invalidLanguage, sourceURL: sourceURL)
        }

        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","language":"ja","url":"show.json"}]}"#.utf8)
        let index = try validator.validateIndex(data: indexData, sourceURL: sourceURL)
        let dangling = Data(#"{"version":1,"id":"show","name":"Show","language":"ja","frames":[{"url":"a.png","caption":"Caption","subsection":"missing"}]}"#.utf8)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateCategory(
                data: dangling,
                documentURL: index.categories[0].url,
                descriptor: index.categories[0].descriptor,
                source: index
            )
        }

        let badTemplate = Data(#"{"version":1,"id":"show","name":"Show","language":"ja","providers":[{"name":"Watch","url":"https://video.example/{unknown}"}],"frames":[]}"#.utf8)
        #expect(throws: CatalogValidationError.self) {
            try validator.validateCategory(
                data: badTemplate,
                documentURL: index.categories[0].url,
                descriptor: index.categories[0].descriptor,
                source: index
            )
        }

        #expect(throws: CatalogValidationError.self) {
            try validator.validateIndex(
                data: Data(repeating: 0, count: CatalogLimits.indexBytes + 1),
                sourceURL: sourceURL
            )
        }
    }

    @Test func bundledExamplesUseTheAuthoritativeSchema() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Tshunhue/Resources")
        let indexData = try Data(contentsOf: resources.appendingPathComponent("Examples/index.json"))
        let index = try validator.validateIndex(data: indexData, sourceURL: sourceURL)
        let categoryData = try Data(contentsOf: resources.appendingPathComponent("Examples/category.json"))
        let category = try validator.validateCategory(
            data: categoryData,
            documentURL: index.categories[0].url,
            descriptor: index.categories[0].descriptor,
            source: index
        )
        #expect(category.frames.count == 1)

        let schemaData = try Data(contentsOf: resources.appendingPathComponent("Schemas/category-v1.schema.json"))
        let schema = try #require(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let frames = try #require(properties["frames"] as? [String: Any])
        #expect(frames["maxItems"] == nil)
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let provider = try #require(definitions["provider"] as? [String: Any])
        let providerProperties = try #require(provider["properties"] as? [String: Any])
        let providerURL = try #require(providerProperties["url"] as? [String: Any])
        #expect(providerURL["format"] == nil)
    }
}

// MARK: - Search

/// Tests locale-aware matching, ranking, and category-filter isolation.
struct SearchIndexTests {
    @Test func matchesWhitespaceSeparatedCJKTermsAndRanksCaptions() async throws {
        let sourceURL = URL(string: "https://example.com/index.json")!
        let captionFrame = makeFrame(sourceURL: sourceURL, id: "a", caption: "春天 花開", tags: [])
        let tagFrame = makeFrame(sourceURL: sourceURL, id: "b", caption: "別的台詞", tags: ["春天", "花開"])
        let index = SearchIndex()
        await index.replace(with: [tagFrame, captionFrame])

        let result = await index.search("春天 花", categoryIDs: [])
        #expect(result.map(\.effectiveID) == ["a", "b"])
    }

    @Test func categoryFiltersUseSourceAndCategoryTogether() async {
        let firstURL = URL(string: "https://one.example/index.json")!
        let secondURL = URL(string: "https://two.example/index.json")!
        let first = makeFrame(sourceURL: firstURL, id: "a", caption: "hello", tags: [])
        let second = makeFrame(sourceURL: secondURL, id: "b", caption: "hello", tags: [])
        let index = SearchIndex()
        await index.replace(with: [first, second])

        let result = await index.search("hello", categoryIDs: [CategoryKey(sourceURL: secondURL, categoryID: "show")])
        #expect(result.map(\.effectiveID) == ["b"])
    }

    @Test func foldsWidthCaseAndDiacriticsWithDeterministicTies() async {
        let sourceURL = URL(string: "https://example.com/index.json")!
        let first = makeFrame(sourceURL: sourceURL, id: "a", caption: "ＣＡＦÉ reaction", tags: [])
        let second = makeFrame(sourceURL: sourceURL, id: "b", caption: "cafe reaction", tags: [])
        let index = SearchIndex()
        await index.replace(with: [first, second])

        let result = await index.search("cafe", categoryIDs: [])
        #expect(result.map(\.effectiveID) == ["a", "b"])
    }

    private func makeFrame(sourceURL: URL, id: String, caption: String, tags: [String]) -> CatalogFrame {
        CatalogFrame(
            identity: FrameIdentity(sourceURL: sourceURL, categoryID: "show", frameID: id),
            sourceName: sourceURL.host() ?? "Source",
            categoryID: "show",
            categoryName: "Show",
            language: "zh-Hant-TW",
            subsection: nil,
            frame: Frame(id: id, url: "image.jpg", caption: caption, tags: tags, subsection: nil, timecode: nil),
            effectiveID: id,
            imageURL: sourceURL.appendingPathComponent("image.jpg"),
            providers: [],
            attribution: nil,
            reportURL: nil,
            categoryOrder: 0,
            subsectionOrder: nil,
            order: id == "a" ? 0 : 1
        )
    }
}

// MARK: - Browsing and Grouping

/// Tests browse-scope resolution and deterministic grouped-grid sections.
struct CatalogBrowsingTests {
    @Test func resolvesSingleScopesAndRecentOrdering() {
        let firstURL = URL(string: "https://one.example/index.json")!
        let secondURL = URL(string: "https://two.example/index.json")!
        let firstSource = makeSource(url: firstURL, name: "First", categoryIDs: ["a", "b"], enabled: ["a", "b"])
        let secondSource = makeSource(url: secondURL, name: "Second", categoryIDs: ["a"], enabled: ["a"])
        let frames = [
            makeFrame(sourceURL: firstURL, sourceName: "First", categoryID: "a", categoryName: "A", id: "1"),
            makeFrame(sourceURL: firstURL, sourceName: "First", categoryID: "b", categoryName: "B", id: "2"),
            makeFrame(sourceURL: secondURL, sourceName: "Second", categoryID: "a", categoryName: "A", id: "3"),
        ]

        let indexFilter = CatalogScopeResolver.categoryFilter(for: .index(firstURL), in: [firstSource, secondSource])
        #expect(indexFilter == [
            CategoryKey(sourceURL: firstURL, categoryID: "a"),
            CategoryKey(sourceURL: firstURL, categoryID: "b"),
        ])
        #expect(CatalogScopeResolver.categoryFilter(for: .recents, in: [firstSource, secondSource]).isEmpty)

        let categoryFrames = CatalogScopeResolver.frames(
            for: .category(CategoryKey(sourceURL: firstURL, categoryID: "b")),
            in: frames,
            recentIdentities: []
        )
        #expect(categoryFrames.map(\.effectiveID) == ["2"])

        let recentFrames = CatalogScopeResolver.frames(
            for: .recents,
            in: frames,
            recentIdentities: [frames[2].identity, frames[0].identity]
        )
        #expect(recentFrames.map(\.effectiveID) == ["3", "1"])
        let hiddenRecentFrames = CatalogScopeResolver.frames(
            for: .recents,
            in: frames.filter { $0.identity != frames[0].identity },
            recentIdentities: [frames[2].identity, frames[0].identity]
        )
        #expect(hiddenRecentFrames.map(\.effectiveID) == ["3"])
        #expect(CatalogScopeResolver.isValid(.index(firstURL), in: [firstSource, secondSource]))
        #expect(!CatalogScopeResolver.isValid(.index(URL(string: "https://missing.example/index.json")!), in: [firstSource, secondSource]))
    }

    @Test func groupsByCatalogOrderAndPreservesFrameOrderWithinSections() throws {
        let firstURL = URL(string: "https://one.example/index.json")!
        let secondURL = URL(string: "https://two.example/index.json")!
        let firstSource = makeSource(url: firstURL, name: "First", categoryIDs: ["first"], enabled: ["first"])
        let secondSource = makeSource(url: secondURL, name: "Second", categoryIDs: ["second"], enabled: ["second"])
        let firstFrame = makeFrame(
            sourceURL: firstURL,
            sourceName: "First",
            categoryID: "first",
            categoryName: "Same Name",
            id: "1"
        )
        let secondFrame = makeFrame(
            sourceURL: secondURL,
            sourceName: "Second",
            categoryID: "second",
            categoryName: "Same Name",
            id: "2"
        )

        let categorySections = FrameSectionBuilder.sections(
            from: [firstFrame, secondFrame],
            scope: .all,
            sources: [secondSource, firstSource]
        )
        #expect(categorySections.map(\.subtitle) == ["Second", "First"])

        let categoryKey = CategoryKey(sourceURL: firstURL, categoryID: "first")
        let episodeOne = Subsection(id: "ep1", name: "Episode 1", providers: nil)
        let episodeTwo = Subsection(id: "ep2", name: "Episode 2", providers: nil)
        let episodeTwoFirst = makeFrame(
            sourceURL: firstURL,
            sourceName: "First",
            categoryID: "first",
            categoryName: "Show",
            id: "ep2-b",
            subsection: episodeTwo,
            subsectionOrder: 1
        )
        let episodeOneFrame = makeFrame(
            sourceURL: firstURL,
            sourceName: "First",
            categoryID: "first",
            categoryName: "Show",
            id: "ep1",
            subsection: episodeOne,
            subsectionOrder: 0
        )
        let episodeTwoSecond = makeFrame(
            sourceURL: firstURL,
            sourceName: "First",
            categoryID: "first",
            categoryName: "Show",
            id: "ep2-a",
            subsection: episodeTwo,
            subsectionOrder: 1
        )
        let ungrouped = makeFrame(
            sourceURL: firstURL,
            sourceName: "First",
            categoryID: "first",
            categoryName: "Show",
            id: "none"
        )
        let subsectionSections = FrameSectionBuilder.sections(
            from: [episodeTwoFirst, episodeOneFrame, episodeTwoSecond, ungrouped],
            scope: .category(categoryKey),
            sources: [firstSource]
        )
        #expect(subsectionSections.map(\.id) == [
            .subsection(categoryKey, "ep1"),
            .subsection(categoryKey, "ep2"),
            .subsection(categoryKey, nil),
        ])
        #expect(subsectionSections.map(\.title) == [
            "Episode 1",
            "Episode 2",
            String(localized: "None"),
        ])
        #expect(subsectionSections[1].frames.map(\.effectiveID) == ["ep2-b", "ep2-a"])
    }

    private func makeSource(
        url: URL,
        name: String,
        categoryIDs: [String],
        enabled: Set<String>
    ) -> SourceSummary {
        SourceSummary(
            id: UUID(),
            sourceURL: url,
            name: name,
            isDefault: false,
            categories: categoryIDs.map { CategoryDescriptor(id: $0, name: $0, language: nil, url: "\($0).json", frames: nil) },
            enabledCategoryIDs: enabled,
            lastSuccessfulRefresh: nil,
            refreshError: nil
        )
    }

    private func makeFrame(
        sourceURL: URL,
        sourceName: String,
        categoryID: String,
        categoryName: String,
        id: String,
        subsection: Subsection? = nil,
        subsectionOrder: Int? = nil
    ) -> CatalogFrame {
        CatalogFrame(
            identity: FrameIdentity(sourceURL: sourceURL, categoryID: categoryID, frameID: id),
            sourceName: sourceName,
            categoryID: categoryID,
            categoryName: categoryName,
            language: "en",
            subsection: subsection,
            frame: Frame(id: id, url: "\(id).png", caption: id, tags: nil, subsection: subsection?.id, timecode: nil),
            effectiveID: id,
            imageURL: sourceURL.appendingPathComponent("\(id).png"),
            providers: [],
            attribution: nil,
            reportURL: nil,
            categoryOrder: 0,
            subsectionOrder: subsectionOrder,
            order: 0
        )
    }
}

// MARK: - Recents

/// Tests archive persistence and merge-safe category selection updates.
struct SourceStoreTests {
    @Test func disabledManifestSurvivesReloadAndConcurrentSelectionsMerge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceURL = URL(string: "https://example.com/index.json")!
        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"a","name":"A","url":"a.json"},{"id":"b","name":"B","url":"b.json"}]}"#.utf8)
        let date = Date(timeIntervalSince1970: 1_000)
        let metadata = HTTPMetadata(etag: "v1", lastModified: nil, expires: date.addingTimeInterval(600))
        let archive = SourceArchive(
            id: UUID(),
            sourceURL: sourceURL,
            isDefault: false,
            index: CachedDocument(data: indexData, metadata: metadata, validatedAt: date),
            enabledCategoryIDs: ["a"],
            categories: [
                "a": CachedDocument(data: Data("a".utf8), metadata: metadata, validatedAt: date),
                "b": CachedDocument(data: Data("b".utf8), metadata: metadata, validatedAt: date),
            ],
            lastSuccessfulRefresh: date,
            lastAttempt: date,
            refreshError: nil
        )
        let store = SourceStore(directory: directory)
        try await store.save(archive)
        try await store.setCategoryEnabled("a", enabled: false, in: archive.id)

        let reloadedStore = SourceStore(directory: directory)
        try await reloadedStore.load()
        let disabled = try #require(await reloadedStore.archive(id: archive.id))
        #expect(disabled.enabledCategoryIDs.isEmpty)
        #expect(disabled.categories["a"]?.data == Data("a".utf8))

        async let first = reloadedStore.setCategoryEnabled("a", enabled: true, in: archive.id)
        async let second = reloadedStore.setCategoryEnabled("b", enabled: true, in: archive.id)
        _ = try await (first, second)
        let merged = try #require(await reloadedStore.archive(id: archive.id))
        #expect(merged.enabledCategoryIDs == ["a", "b"])
        #expect(Set(merged.categories.keys) == ["a", "b"])
    }
}

/// Tests bounded recent-item persistence and scoped removal.
struct RecentStoreTests {
    @Test func storesFiveDeduplicatedItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecentStore(fileURL: directory.appendingPathComponent("recent.json"))
        let source = URL(string: "https://example.com/index.json")!
        for index in 0..<7 {
            try await store.record(FrameIdentity(sourceURL: source, categoryID: "show", frameID: "\(index)"))
        }
        try await store.record(FrameIdentity(sourceURL: source, categoryID: "show", frameID: "4"))
        let values = await store.all()
        #expect(values.count == 5)
        #expect(values.first?.frameID == "4")
    }

    @Test func removesCategoriesSourcesAndEverything() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecentStore(fileURL: directory.appendingPathComponent("recent.json"))
        let first = URL(string: "https://one.example/index.json")!
        let second = URL(string: "https://two.example/index.json")!
        try await store.record(FrameIdentity(sourceURL: first, categoryID: "a", frameID: "1"))
        try await store.record(FrameIdentity(sourceURL: first, categoryID: "b", frameID: "2"))
        try await store.record(FrameIdentity(sourceURL: second, categoryID: "a", frameID: "3"))

        try await store.remove(categoryID: "a", sourceURL: first)
        #expect(await store.all().map(\.frameID) == ["3", "2"])
        try await store.remove(sourceURL: second)
        #expect(await store.all().map(\.frameID) == ["2"])
        try await store.clear()
        #expect(await store.all().isEmpty)
    }
}

// MARK: - Synchronization

/// Tests conditional refreshes and last-known-good archive behavior.
struct SyncTests {
    @Test func freshnessUsesServerExpiryThenTheConfiguredRefreshInterval() {
        let date = Date(timeIntervalSince1970: 10_000)
        let future = CachedDocument(
            data: Data(),
            metadata: HTTPMetadata(etag: nil, lastModified: nil, expires: date.addingTimeInterval(60)),
            validatedAt: nil
        )
        let expired = CachedDocument(
            data: Data(),
            metadata: HTTPMetadata(etag: nil, lastModified: nil, expires: date),
            validatedAt: date
        )
        let fallback = CachedDocument(
            data: Data(),
            metadata: HTTPMetadata(etag: nil, lastModified: nil, expires: nil),
            validatedAt: date.addingTimeInterval(-172_800)
        )
        let migrated = CachedDocument(
            data: Data(),
            metadata: HTTPMetadata(etag: nil, lastModified: nil, expires: nil)
        )

        #expect(future.isFresh(at: date, refreshFrequency: .daily))
        #expect(!expired.isFresh(at: date, refreshFrequency: .manual))
        #expect(fallback.isFresh(at: date, refreshFrequency: .weekly))
        #expect(!fallback.isFresh(at: date, refreshFrequency: .daily))
        #expect(fallback.isFresh(at: date, refreshFrequency: .manual))
        #expect(!migrated.isFresh(at: date, refreshFrequency: .manual))
    }

    @Test func freshDisabledManifestNeedsNoRequestButExpiredManifestDownloadsAsNew() async throws {
        let date = Date(timeIntervalSince1970: 20_000)
        let sourceURL = URL(string: "https://example.com/index.json")!
        let categoryURL = URL(string: "https://example.com/show.json")!
        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","language":"ja","url":"show.json"}]}"#.utf8)
        let oldData = Data(#"{"version":1,"id":"show","name":"Show","language":"ja","frames":[{"url":"old.png","caption":"Old"}]}"#.utf8)
        let newData = Data(#"{"version":1,"id":"show","name":"Show","language":"ja","frames":[{"url":"new.png","caption":"New"}]}"#.utf8)
        let client = ScriptedHTTPClient(steps: [
            .init(url: categoryURL, status: 200, data: newData, headers: ["ETag": "new"]),
        ])
        let service = CatalogSyncService(client: client, now: { date })
        var archive = SourceArchive(
            id: UUID(),
            sourceURL: sourceURL,
            isDefault: false,
            index: CachedDocument(
                data: indexData,
                metadata: HTTPMetadata(etag: "index", lastModified: nil, expires: nil),
                validatedAt: date
            ),
            enabledCategoryIDs: [],
            categories: [
                "show": CachedDocument(
                    data: oldData,
                    metadata: HTTPMetadata(etag: "old", lastModified: nil, expires: date.addingTimeInterval(60)),
                    validatedAt: date
                ),
            ],
            lastSuccessfulRefresh: date,
            lastAttempt: date,
            refreshError: nil
        )

        #expect(try await service.freshCachedCategoryDocument("show", in: archive, refreshFrequency: .weekly)?.data == oldData)
        #expect(await client.requests.isEmpty)

        archive.categories["show"]?.metadata.expires = date
        #expect(try await service.freshCachedCategoryDocument("show", in: archive, refreshFrequency: .weekly) == nil)
        let replacement = try await service.downloadCategoryDocument("show", in: archive)
        #expect(replacement.data == newData)
        #expect(replacement.validatedAt == date)
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].validators == nil)
    }

    @Test func refreshContactsOnlyEnabledCategoriesAndPrunesExpiredDisabledCache() async throws {
        let date = Date(timeIntervalSince1970: 30_000)
        let sourceURL = URL(string: "https://example.com/index.json")!
        let enabledURL = URL(string: "https://example.com/enabled.json")!
        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"enabled","name":"Enabled","url":"enabled.json"},{"id":"fresh","name":"Fresh","url":"fresh.json"},{"id":"expired","name":"Expired","url":"expired.json"}]}"#.utf8)
        let enabledData = Data(#"{"version":1,"id":"enabled","name":"Enabled","language":"en","frames":[]}"#.utf8)
        let client = ScriptedHTTPClient(steps: [
            .init(url: sourceURL, status: 304, data: nil),
            .init(url: enabledURL, status: 304, data: nil),
        ])
        let service = CatalogSyncService(client: client, now: { date })
        let freshMetadata = HTTPMetadata(etag: "fresh", lastModified: nil, expires: date.addingTimeInterval(60))
        let archive = SourceArchive(
            id: UUID(),
            sourceURL: sourceURL,
            isDefault: false,
            index: CachedDocument(
                data: indexData,
                metadata: HTTPMetadata(etag: "index", lastModified: nil, expires: date),
                validatedAt: date.addingTimeInterval(-60)
            ),
            enabledCategoryIDs: ["enabled"],
            categories: [
                "enabled": CachedDocument(
                    data: enabledData,
                    metadata: HTTPMetadata(etag: "enabled", lastModified: nil, expires: date),
                    validatedAt: date.addingTimeInterval(-60)
                ),
                "fresh": CachedDocument(data: Data("fresh".utf8), metadata: freshMetadata, validatedAt: date),
                "expired": CachedDocument(
                    data: Data("expired".utf8),
                    metadata: HTTPMetadata(etag: "expired", lastModified: nil, expires: date),
                    validatedAt: date.addingTimeInterval(-60)
                ),
            ],
            lastSuccessfulRefresh: date.addingTimeInterval(-60),
            lastAttempt: date.addingTimeInterval(-60),
            refreshError: nil
        )

        let refreshed = await service.refresh(archive, refreshFrequency: .weekly)
        #expect(refreshed.enabledCategoryIDs == ["enabled"])
        #expect(Set(refreshed.categories.keys) == ["enabled", "fresh"])
        let requests = await client.requests
        #expect(requests.map(\.url) == [sourceURL, enabledURL])
        #expect(requests[0].validators?.etag == "index")
        #expect(requests[1].validators?.etag == "enabled")
    }

    @Test func conditionalRefreshPreservesTheCompleteLastKnownGoodCatalog() async throws {
        let sourceURL = URL(string: "https://example.com/index.json")!
        let categoryURL = URL(string: "https://example.com/show.json")!
        let indexData = Data(#"{"version":1,"name":"Example","categories":[{"id":"show","name":"Show","language":"ja","url":"show.json"}]}"#.utf8)
        let categoryData = Data(#"{"version":1,"id":"show","name":"Show","language":"ja","frames":[{"url":"a.png","caption":"Caption"}]}"#.utf8)
        let client = ScriptedHTTPClient(steps: [
            .init(url: sourceURL, status: 200, data: indexData, headers: ["ETag": "index-v1"]),
            .init(url: categoryURL, status: 200, data: categoryData, headers: ["ETag": "category-v1"]),
            .init(url: sourceURL, status: 304, data: nil),
            .init(url: categoryURL, status: 200, data: Data("not json".utf8)),
        ])
        let service = CatalogSyncService(client: client)
        let source = try await service.createSource(url: sourceURL, isDefault: false)
        let enabled = try await service.setCategory("show", enabled: true, in: source)
        let refreshed = await service.refresh(enabled)

        #expect(refreshed.index.data == enabled.index.data)
        #expect(refreshed.categories["show"]?.data == enabled.categories["show"]?.data)
        #expect(refreshed.refreshError != nil)
        let requests = await client.requests
        #expect(requests[2].validators?.etag == "index-v1")
        #expect(requests[3].validators?.etag == "category-v1")
    }
}

// MARK: - Image Cache and Transfers

/// Tests cache recovery and the JPEG-only outbound transfer contract.
struct ImageRepositoryTests {
    @Test func corruptIndexIsDiscardedWithoutBlockingStartup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        let orphanURL = directory.appendingPathComponent("orphan.image")
        try Data("broken".utf8).write(to: indexURL)
        try Data("orphan".utf8).write(to: orphanURL)

        let repository = ImageRepository(directory: directory, byteBudget: 1_024)
        try await repository.load()

        #expect(await repository.cacheSize() == 0)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test func readOnlyCacheIgnoresCorruptionWithoutRepairingSharedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        let orphanURL = directory.appendingPathComponent("orphan.image")
        let brokenIndex = Data("broken".utf8)
        try brokenIndex.write(to: indexURL)
        try Data("orphan".utf8).write(to: orphanURL)

        let repository = ImageRepository(
            directory: directory,
            byteBudget: 1_024,
            access: .readOnly
        )
        try await repository.load()

        #expect(await repository.cacheSize() == 0)
        #expect(try Data(contentsOf: indexURL) == brokenIndex)
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test func readOnlyCacheServesLocalBytesWithoutWritingOrUsingNetwork() async throws {
        let cachedURL = URL(string: "https://images.example/cached.jpg")!
        let missingURL = URL(string: "https://images.example/missing.jpg")!
        let jpeg = try makeImageData(
            type: .jpeg,
            width: 2,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: ScriptedHTTPClient(steps: [.init(url: cachedURL, status: 200, data: jpeg)])
        )
        try await writer.load()
        _ = try await writer.asset(for: cachedURL)

        let indexURL = directory.appendingPathComponent("index.json")
        let markerDate = Date(timeIntervalSinceReferenceDate: 123_456)
        try FileManager.default.setAttributes([.modificationDate: markerDate], ofItemAtPath: indexURL.path)
        let originalIndex = try Data(contentsOf: indexURL)
        let originalDate = try #require(
            FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date
        )
        let client = ScriptedHTTPClient(steps: [])
        let reader = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            access: .readOnly,
            client: client
        )
        try await reader.load()

        #expect(try await reader.asset(for: cachedURL).data == jpeg)
        do {
            _ = try await reader.asset(for: missingURL)
            Issue.record("Expected a read-only cache miss")
        } catch ImageRepositoryError.notCached {
            // Expected: the keyboard decides whether Full Access permits a temporary download.
        }
        #expect(await client.requests.isEmpty)
        #expect(try Data(contentsOf: indexURL) == originalIndex)
        let finalDate = try #require(
            FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date
        )
        #expect(finalDate == originalDate)
    }

    @Test func cacheFilenameUsesDetectedImageTypeAndSurvivesReload() async throws {
        let imageURL = URL(string: "https://images.example/misleading.png")!
        let jpeg = try makeImageData(
            type: .jpeg,
            width: 2,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: ScriptedHTTPClient(steps: [.init(url: imageURL, status: 200, data: jpeg)])
        )
        try await repository.load()

        let downloaded = try await repository.asset(for: imageURL)
        #expect(downloaded.type.conforms(to: .jpeg))
        #expect(downloaded.localURL.pathExtension == UTType.jpeg.preferredFilenameExtension)
        #expect(FileManager.default.fileExists(atPath: downloaded.localURL.path))

        let reloaded = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: ScriptedHTTPClient(steps: [])
        )
        try await reloaded.load()
        #expect(try await reloaded.asset(for: imageURL).localURL == downloaded.localURL)
    }

    @Test func serverExpiryDoesNotOverrideTheWeeklyImagePolicy() async throws {
        let imageURL = URL(string: "https://images.example/frame.jpg")!
        let jpeg = try makeImageData(
            type: .jpeg,
            width: 2,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let downloadedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let initialRepository = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: ScriptedHTTPClient(steps: [
                .init(url: imageURL, status: 200, data: jpeg, expires: downloadedAt.addingTimeInterval(300)),
            ]),
            now: { downloadedAt }
        )
        try await initialRepository.load()
        _ = try await initialRepository.asset(for: imageURL)

        let client = ScriptedHTTPClient(steps: [])
        let reloaded = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: client,
            now: { downloadedAt.addingTimeInterval(600) }
        )
        try await reloaded.load()

        #expect(try await reloaded.asset(for: imageURL).data == jpeg)
        await Task.yield()
        #expect(await client.requests.isEmpty)
    }

    @Test func staleCacheReturnsBeforeItsCoalescedBackgroundRefresh() async throws {
        let imageURL = URL(string: "https://images.example/frame.jpg")!
        let jpeg = try makeImageData(
            type: .jpeg,
            width: 2,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let downloadedAt = Date(timeIntervalSinceReferenceDate: 20_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let initialRepository = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: ScriptedHTTPClient(steps: [
                .init(url: imageURL, status: 200, data: jpeg, headers: ["ETag": "frame-v1"]),
            ]),
            now: { downloadedAt }
        )
        try await initialRepository.load()
        _ = try await initialRepository.asset(for: imageURL)

        let client = GatedHTTPClient()
        let staleRepository = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: client,
            now: { downloadedAt.addingTimeInterval(604_801) }
        )
        try await staleRepository.load()

        // Both reads finish while the conditional request remains deliberately suspended.
        #expect(try await staleRepository.asset(for: imageURL).data == jpeg)
        await client.waitForRequest()
        #expect(try await staleRepository.asset(for: imageURL).data == jpeg)
        #expect(await client.requests.count == 1)
        #expect(await client.requests.first?.validators?.etag == "frame-v1")

        await client.complete(status: 304, data: nil, headers: ["ETag": "frame-v1"])
        let indexURL = directory.appendingPathComponent("index.json")
        #expect(await waitUntil {
            guard let data = try? Data(contentsOf: indexURL) else { return false }
            return String(decoding: data, as: UTF8.self).contains("lastRevalidationAttempt")
        })

        _ = try await staleRepository.asset(for: imageURL)
        await Task.yield()
        #expect(await client.requests.count == 1)
    }

    @Test func failedBackgroundRefreshKeepsTheLocalImageAndDefersRetry() async throws {
        let imageURL = URL(string: "https://images.example/frame.jpg")!
        let jpeg = try makeImageData(
            type: .jpeg,
            width: 2,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let downloadedAt = Date(timeIntervalSinceReferenceDate: 25_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let initialRepository = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: ScriptedHTTPClient(steps: [.init(url: imageURL, status: 200, data: jpeg)]),
            now: { downloadedAt }
        )
        try await initialRepository.load()
        _ = try await initialRepository.asset(for: imageURL)

        let client = AlwaysFailingHTTPClient()
        let staleRepository = ImageRepository(
            directory: directory,
            byteBudget: 1_024 * 1_024,
            client: client,
            now: { downloadedAt.addingTimeInterval(604_801) }
        )
        try await staleRepository.load()
        #expect(try await staleRepository.asset(for: imageURL).data == jpeg)

        let indexURL = directory.appendingPathComponent("index.json")
        #expect(await waitUntil {
            guard let data = try? Data(contentsOf: indexURL) else { return false }
            return String(decoding: data, as: UTF8.self).contains("lastRevalidationAttempt")
        })
        #expect(await client.requestCount == 1)

        #expect(try await staleRepository.asset(for: imageURL).data == jpeg)
        await Task.yield()
        #expect(await client.requestCount == 1)
    }

    @Test func backgroundReplacementInvalidatesDerivedThumbnails() async throws {
        let imageURL = URL(string: "https://images.example/frame.jpg")!
        let firstJPEG = try makeImageData(
            type: .jpeg,
            width: 2,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let replacementJPEG = try makeImageData(
            type: .jpeg,
            width: 1,
            height: 2,
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 30_000))
        let client = ScriptedHTTPClient(steps: [
            .init(url: imageURL, status: 200, data: firstJPEG, headers: ["ETag": "frame-v1"]),
            .init(url: imageURL, status: 200, data: replacementJPEG, headers: ["ETag": "frame-v2"]),
        ])
        let repository = ImageRepository(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            byteBudget: 1_024 * 1_024,
            client: client,
            now: { clock.now }
        )
        try await repository.load()

        let original = try await repository.thumbnail(for: imageURL, maxPixelSize: 100)
        #expect(original.image.width == 2)
        #expect(original.image.height == 1)

        clock.advance(by: 604_801)
        _ = try await repository.asset(for: imageURL)
        #expect(await waitUntil {
            guard let asset = try? await repository.asset(for: imageURL) else { return false }
            return asset.width == 1 && asset.height == 2
        })

        let replacement = try await repository.thumbnail(for: imageURL, maxPixelSize: 100)
        #expect(replacement.image.width == 1)
        #expect(replacement.image.height == 2)
        #expect(await client.requests.count == 2)
    }

    @Test func jpegSourcesArePreservedByteForByte() throws {
        let png = try makeImageData(type: .png, width: 1, height: 1, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let jpeg = try JPEGEncoder.data(for: imageAsset(data: png, type: .png, width: 1, height: 1))
        let preserved = try JPEGEncoder.data(for: imageAsset(data: jpeg, type: .jpeg, width: 1, height: 1))
        #expect(preserved == jpeg)
    }

    @Test func nonJPEGExportUsesJPEGWhiteMatteAndJPGFilename() throws {
        let transparentPNG = try makeImageData(
            type: .png,
            width: 1,
            height: 1,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        )
        let jpeg = try JPEGEncoder.data(
            for: imageAsset(data: transparentPNG, type: .png, width: 1, height: 1)
        )
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let pixel = try rgbaPixel(from: jpeg)
        #expect(pixel[0] > 240)
        #expect(pixel[1] > 240)
        #expect(pixel[2] > 240)

        let frame = transferFrame(caption: "Bad / Name")
        let fileURL = try TransferService.exportJPEGFile(for: frame, data: jpeg)
        #expect(fileURL.lastPathComponent == "Bad Name.jpg")
        #expect(try Data(contentsOf: fileURL) == jpeg)
    }

    @Test func nonJPEGExportAppliesSourceOrientation() throws {
        let rotatedTIFF = try makeImageData(
            type: .tiff,
            width: 2,
            height: 1,
            color: CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            orientation: 6
        )
        let jpeg = try JPEGEncoder.data(
            for: imageAsset(data: rotatedTIFF, type: .tiff, width: 2, height: 1)
        )
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2)
    }

    @Test func failedJPEGPreparationCanRetryWithoutPrematureRecent() async throws {
        let imageURL = URL(string: "https://images.example/broken.png")!
        let jpeg = try makeImageData(
            type: .jpeg,
            width: 1,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let client = ScriptedHTTPClient(steps: [
            .init(url: imageURL, status: 200, data: Data("not an image".utf8)),
            .init(url: imageURL, status: 200, data: jpeg),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = ImageRepository(
            directory: directory.appendingPathComponent("images"),
            byteBudget: 1_024 * 1_024,
            client: client
        )
        try await repository.load()
        let recentStore = RecentStore(fileURL: directory.appendingPathComponent("recent.json"))
        try await recentStore.load()
        let item = FrameTransferItem(
            frame: transferFrame(caption: "Broken", imageURL: imageURL),
            repository: repository,
            recentStore: recentStore
        )

        do {
            _ = try await item.previewImage.jpegData()
            Issue.record("Expected invalid image data to fail JPEG preparation")
        } catch {
            // Expected: failed preview preparation remains side-effect-free and retryable.
        }
        #expect(await recentStore.all().isEmpty)

        #expect(try await item.jpegData() == jpeg)
        #expect(await waitUntil { await recentStore.all() == [item.frame.identity] })
        #expect(await client.requests.count == 2)
    }

    @Test func fileAndDataTransfersSharePreparationAndRecentPublication() async throws {
        let imageURL = URL(string: "https://images.example/frame.jpg")!
        let jpeg = try makeImageData(
            type: .jpeg,
            width: 2,
            height: 1,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let client = ScriptedHTTPClient(steps: [
            .init(url: imageURL, status: 200, data: jpeg),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let imageDirectory = directory.appendingPathComponent("images")
        let repository = ImageRepository(
            directory: imageDirectory,
            byteBudget: 1_024 * 1_024,
            client: client
        )
        try await repository.load()
        let recentStore = RecentStore(fileURL: directory.appendingPathComponent("recent.json"))
        try await recentStore.load()
        let callbackCounter = AsyncCounter()
        let frame = transferFrame(caption: "Shared", imageURL: imageURL)
        let item = FrameTransferItem(
            frame: frame,
            repository: repository,
            recentStore: recentStore
        ) {
            await callbackCounter.increment()
        }

        #expect(try await item.previewImage.jpegData() == jpeg)
        #expect(await recentStore.all().isEmpty)
        #expect(await callbackCounter.value == 0)

        async let exportedData = item.jpegData()
        async let exportedURL = item.jpegFileURL()
        let (data, fileURL) = try await (exportedData, exportedURL)

        #expect(data == jpeg)
        #expect(fileURL.deletingLastPathComponent().standardizedFileURL.path == imageDirectory.standardizedFileURL.path)
        #expect(try Data(contentsOf: fileURL) == jpeg)
        #expect(await client.requests.count == 1)
        #expect(await waitUntil {
            let recents = await recentStore.all()
            let callbackCount = await callbackCounter.value
            return recents == [frame.identity] && callbackCount == 1
        })

        _ = try await item.jpegData()
        await Task.yield()
        #expect(await callbackCounter.value == 1)
    }

    // MARK: Fixtures

    /// Wraps fixture bytes in an image asset with a disposable local URL.
    private func imageAsset(data: Data, type: UTType, width: Int, height: Int) -> ImageAsset {
        ImageAsset(
            data: data,
            type: type,
            width: width,
            height: height,
            localURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    /// Encodes a one-frame image fixture with optional orientation metadata.
    private func makeImageData(
        type: UTType,
        width: Int,
        height: Int,
        color: CGColor,
        orientation: Int? = nil
    ) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Renders the first image pixel into an sRGB RGBA buffer.
    private func rgbaPixel(from data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        #expect(rendered)
        return pixel
    }

    /// Creates a representative frame for transfer tests.
    private func transferFrame(caption: String, imageURL: URL? = nil) -> CatalogFrame {
        let sourceURL = URL(string: "https://example.com/index.json")!
        let resolvedImageURL = imageURL ?? sourceURL.appendingPathComponent("frame.png")
        return CatalogFrame(
            identity: FrameIdentity(sourceURL: sourceURL, categoryID: "show", frameID: "frame"),
            sourceName: "Example",
            categoryID: "show",
            categoryName: "Show",
            language: "en",
            subsection: nil,
            frame: Frame(id: "frame", url: resolvedImageURL.absoluteString, caption: caption, tags: nil, subsection: nil, timecode: nil),
            effectiveID: "frame",
            imageURL: resolvedImageURL,
            providers: [],
            attribution: nil,
            reportURL: nil,
            categoryOrder: 0,
            subsectionOrder: nil,
            order: 0
        )
    }
}

/// A deterministic HTTP client that returns scripted responses and records requests.
private actor ScriptedHTTPClient: HTTPFetching {
    /// One expected request and its canned response.
    struct Step: Sendable {
        let url: URL
        let status: Int
        let data: Data?
        var expires: Date? = nil
        var headers: [String: String] = [:]
    }

    /// One captured request for validator and limit assertions.
    struct Request: Sendable {
        let url: URL
        let validators: HTTPMetadata?
        let byteLimit: Int
    }

    private var steps: [Step]
    private(set) var requests: [Request] = []

    /// Creates a client that consumes responses in order.
    init(steps: [Step]) {
        self.steps = steps
    }

    /// Records a request and returns the next matching scripted response.
    func get(_ url: URL, validators: HTTPMetadata?, byteLimit: Int) async throws -> HTTPResult {
        requests.append(Request(url: url, validators: validators, byteLimit: byteLimit))
        guard !steps.isEmpty else { throw HTTPClientError.invalidResponse }
        let step = steps.removeFirst()
        guard step.url == url else { throw HTTPClientError.invalidResponse }
        let response = HTTPURLResponse(
            url: url,
            statusCode: step.status,
            httpVersion: "HTTP/1.1",
            headerFields: step.headers
        )!
        return HTTPResult(
            data: step.data,
            metadata: HTTPMetadata(
                etag: step.headers["ETag"],
                lastModified: step.headers["Last-Modified"],
                expires: step.expires
            ),
            response: response
        )
    }
}

/// An HTTP client whose single response remains suspended until the test releases it.
private actor GatedHTTPClient: HTTPFetching {
    private(set) var requests: [ScriptedHTTPClient.Request] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<HTTPResult, Error>?

    /// Records a request and waits for an explicit test response.
    func get(_ url: URL, validators: HTTPMetadata?, byteLimit: Int) async throws -> HTTPResult {
        requests.append(.init(url: url, validators: validators, byteLimit: byteLimit))
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters = []
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }

    /// Suspends until the repository begins its background request.
    func waitForRequest() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    /// Releases the pending request with a canned HTTP response.
    func complete(status: Int, data: Data?, headers: [String: String] = [:]) {
        guard let request = requests.last, let responseContinuation else { return }
        self.responseContinuation = nil
        let response = HTTPURLResponse(
            url: request.url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        responseContinuation.resume(returning: HTTPResult(
            data: data,
            metadata: HTTPMetadata(
                etag: headers["ETag"],
                lastModified: headers["Last-Modified"],
                expires: nil
            ),
            response: response
        ))
    }
}

/// An HTTP client that records attempts and immediately fails them.
private actor AlwaysFailingHTTPClient: HTTPFetching {
    private(set) var requestCount = 0

    /// Records the request before returning a representative transport failure.
    func get(_ url: URL, validators: HTTPMetadata?, byteLimit: Int) async throws -> HTTPResult {
        requestCount += 1
        throw HTTPClientError.invalidResponse
    }
}

/// A lock-protected clock used to advance cache age without waiting in tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    /// Creates a clock at a known instant.
    init(_ date: Date) {
        self.date = date
    }

    /// Returns the current test instant.
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    /// Advances the test instant by a fixed interval.
    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// Counts asynchronous callbacks without exposing mutable shared state.
private actor AsyncCounter {
    private(set) var value = 0

    /// Increments the counter once.
    func increment() { value += 1 }
}

/// Polls a short asynchronous condition used to observe background actor work.
private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

// MARK: - Checked-Out Data

/// Validates the nested data repository when a local checkout is available.
struct DataCheckoutTests {
    @Test func validatesLocalCheckoutWhenPresent() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let dataDirectory = root.appendingPathComponent("data")
        let indexURL = dataDirectory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }

        let validator = CatalogValidator()
        let hostedURL = URL(string: "https://example.invalid/index.json")!
        let index = try validator.validateIndex(data: Data(contentsOf: indexURL), sourceURL: hostedURL)
        for descriptor in index.categories {
            let relativePath = descriptor.url.path.replacingOccurrences(of: "/", with: "", options: .anchored)
            let localURL = dataDirectory.appendingPathComponent(relativePath)
            _ = try validator.validateCategory(
                data: Data(contentsOf: localURL),
                documentURL: descriptor.url,
                descriptor: descriptor.descriptor,
                source: index
            )
        }
    }
}
