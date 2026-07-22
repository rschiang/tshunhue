//
//  PreviewData.swift
//  Tshunhue
//
//  Supplies lightweight, debug-only catalog fixtures for SwiftUI previews.
//

#if DEBUG
import Foundation

/// Deterministic sample state used only by Xcode previews.
@MainActor
enum PreviewData {
    /// Creates an isolated app model populated with representative frames.
    static func model() -> AppModel {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tshunhue Preview", isDirectory: true)

        // Populated preview models skip app startup, so prepare the cache directory here.
        try? FileManager.default.createDirectory(
            at: baseDirectory.appendingPathComponent("Image Cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        let model = AppModel(baseDirectory: baseDirectory)
        model.sources = [source]
        model.allFrames = frames
        model.displayedFrames = frames
        return model
    }

    /// A representative source with one enabled category.
    static let source = SourceSummary(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sourceURL: URL(string: "https://example.com/index.json")!,
        name: "Tshun-lit-iánn",
        isDefault: true,
        categories: [
            CategoryDescriptor(
                id: "spring-flowers",
                name: "Spring Flowers",
                language: "zh-Hant-TW",
                url: "category.json",
                frames: 4
            ),
        ],
        enabledCategoryIDs: ["spring-flowers"],
        lastSuccessfulRefresh: nil,
        refreshError: nil
    )

    /// Four representative frames used by grid and root previews.
    static let frames = [
        makeFrame(
            id: "spring",
            caption: "Why did you do Shades of Spring?",
            seed: "spring",
            tags: ["Crychic", "Soyo"],
            subsectionID: "episode-1",
            subsectionName: "Episode 1",
            subsectionOrder: 0,
            order: 0,
            seconds: 42
        ),
        makeFrame(
            id: "issho",
            caption: "Will you form a band with me for life?",
            seed: "issho",
            tags: ["Tomorin"],
            subsectionID: "episode-1",
            subsectionName: "Episode 1",
            subsectionOrder: 0,
            order: 1,
            seconds: 96
        ),
        makeFrame(
            id: "resurrection",
            caption: "Now is the time for resurrection.",
            seed: "resurrection",
            tags: ["Shouko"],
            subsectionID: "episode-2",
            subsectionName: "Episode 2",
            subsectionOrder: 1,
            order: 2,
            seconds: 128
        ),
        makeFrame(
            id: "ordinary",
            caption: "What is normal and what is ordinary?",
            seed: "ordinary",
            tags: ["MyGO"],
            subsectionID: "episode-2",
            subsectionName: "Episode 2",
            subsectionOrder: 1,
            order: 3,
            seconds: 180
        ),
    ]

    /// The first representative frame used by single-item previews.
    static let frame = frames[0]

    /// Builds one deterministic frame while keeping repeated preview metadata concise.
    private static func makeFrame(
        id: String,
        caption: String,
        seed: String,
        tags: [String],
        subsectionID: String,
        subsectionName: String,
        subsectionOrder: Int,
        order: Int,
        seconds: TimeInterval
    ) -> CatalogFrame {
        let imageURL = URL(string: "https://picsum.photos/seed/tshunhue-\(seed)/640/360")!
        return CatalogFrame(
            identity: FrameIdentity(
                sourceURL: URL(string: "https://example.com/index.json")!,
                categoryID: "spring-flowers",
                frameID: id
            ),
            sourceName: "Tshun-lit-iánn",
            categoryID: "spring-flowers",
            categoryName: "Spring Flowers",
            language: "zh-Hant-TW",
            subsection: Subsection(id: subsectionID, name: subsectionName, providers: nil),
            frame: Frame(
                id: id,
                url: imageURL.absoluteString,
                caption: caption,
                tags: tags,
                subsection: subsectionID,
                timecode: try? Timecode(seconds: seconds)
            ),
            effectiveID: id,
            imageURL: imageURL,
            providers: [Provider(name: "YouTube", url: "https://youtu.be/dQw4w9WgXcQ?t={seconds}")],
            attribution: Attribution(text: "Unsplash", url: "https://unsplash.com"),
            reportURL: URL(string: "https://picsum.photos/"),
            categoryOrder: 0,
            subsectionOrder: subsectionOrder,
            order: order
        )
    }
}
#endif
