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
    /// Creates an isolated app model populated with one representative frame.
    static func model() -> AppModel {
        let model = AppModel(
            baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("Tshunhue Preview", isDirectory: true)
        )
        model.sources = [source]
        model.allFrames = [frame]
        model.displayedFrames = [frame]
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
                frames: 1
            ),
        ],
        enabledCategoryIDs: ["spring-flowers"],
        lastSuccessfulRefresh: nil,
        refreshError: nil
    )

    /// A representative frame with subsection, tag, attribution, and provider metadata.
    static let frame = CatalogFrame(
        identity: FrameIdentity(
            sourceURL: URL(string: "https://example.com/index.json")!,
            categoryID: "spring-flowers",
            frameID: "welcome"
        ),
        sourceName: "Tshun-lit-iánn",
        categoryID: "spring-flowers",
        categoryName: "Spring Flowers",
        language: "zh-Hant-TW",
        subsection: Subsection(id: "episode-1", name: "Episode 1", providers: nil),
        frame: Frame(
            id: "welcome",
            url: "https://example.com/welcome.jpg",
            caption: "Welcome to Tshunhue!",
            tags: ["welcome", "spring"],
            subsection: "episode-1",
            timecode: try? Timecode(seconds: 42)
        ),
        effectiveID: "welcome",
        imageURL: URL(string: "https://example.com/welcome.jpg")!,
        providers: [Provider(name: "Watch", url: "https://example.com/watch?t={seconds}")],
        attribution: Attribution(text: "Preview artwork", url: "https://example.com"),
        reportURL: URL(string: "https://example.com/report"),
        categoryOrder: 0,
        subsectionOrder: 0,
        order: 0
    )
}
#endif
