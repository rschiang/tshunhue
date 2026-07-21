import Foundation
import Testing
@testable import Tshunhue

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
            order: id == "a" ? 0 : 1
        )
    }
}

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

struct SyncTests {
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
}

private actor ScriptedHTTPClient: HTTPFetching {
    struct Step: Sendable {
        let url: URL
        let status: Int
        let data: Data?
        var headers: [String: String] = [:]
    }

    struct Request: Sendable {
        let url: URL
        let validators: HTTPMetadata?
        let byteLimit: Int
    }

    private var steps: [Step]
    private(set) var requests: [Request] = []

    init(steps: [Step]) {
        self.steps = steps
    }

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
                expires: nil
            ),
            response: response
        )
    }
}

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
