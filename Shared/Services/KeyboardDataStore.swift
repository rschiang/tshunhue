//
//  KeyboardDataStore.swift
//  Tshunhue
//
//  Reads app-owned catalogs and images for the reusable iOS keyboard model.
//

import Foundation

/// Loads and validates enabled frames without mutating the containing app's source archives.
private actor KeyboardCatalogLoader {
    /// Resolves every enabled frame in deterministic source and category order.
    func frames(in applicationSupport: URL) throws -> [CatalogFrame] {
        let directory = applicationSupport.appendingPathComponent("Sources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("source-") && $0.pathExtension == "json" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archives = files
            .compactMap { try? decoder.decode(SourceArchive.self, from: Data(contentsOf: $0)) }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.sourceURL.absoluteString < rhs.sourceURL.absoluteString
            }
        let validator = CatalogValidator()
        var loaded: [CatalogFrame] = []
        for archive in archives {
            try Task.checkCancellation()
            guard let index = try? validator.validateIndex(
                data: archive.index.data,
                sourceURL: archive.sourceURL
            ) else { continue }
            for descriptor in index.categories
            where archive.enabledCategoryIDs.contains(descriptor.descriptor.id) {
                try Task.checkCancellation()
                guard let document = archive.categories[descriptor.descriptor.id],
                      let category = try? validator.validateCategory(
                        data: document.data,
                        documentURL: descriptor.url,
                        descriptor: descriptor.descriptor,
                        source: index
                      ) else { continue }
                loaded.append(contentsOf: category.frames)
            }
        }
        return loaded
    }
}

/// Prioritizes the shared read-only cache and confines network misses to a temporary session cache.
private actor KeyboardImageProvider {
    /// A keyboard process retains at most 32 MiB of downloaded source images.
    private static let sessionBudget = 32 * 1_024 * 1_024

    private let sharedRepository: ImageRepository
    private let sessionRepository: ImageRepository

    /// Creates repositories for the app-owned cache and Full Access network misses.
    init(applicationSupport: URL) {
        sharedRepository = ImageRepository(
            directory: applicationSupport.appendingPathComponent("Image Cache", isDirectory: true),
            byteBudget: 256 * 1_024 * 1_024,
            access: .readOnly
        )
        sessionRepository = ImageRepository(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("TshunhueKeyboard-(UUID().uuidString)", isDirectory: true),
            byteBudget: Self.sessionBudget
        )
    }

    /// Loads both indexes while keeping the shared repository read-only.
    func load() async throws {
        try await sharedRepository.load()
        try await sessionRepository.load()
    }

    /// Returns a shared cached asset before attempting a session download.
    func asset(for url: URL) async throws -> ImageAsset {
        do {
            return try await sharedRepository.asset(for: url)
        } catch ImageRepositoryError.notCached {
            return try await sessionRepository.asset(for: url)
        }
    }

    /// Returns a shared cached thumbnail before attempting a session download.
    func thumbnail(for url: URL, maxPixelSize: Int) async throws -> ImageThumbnail {
        do {
            return try await sharedRepository.thumbnail(for: url, maxPixelSize: maxPixelSize)
        } catch ImageRepositoryError.notCached {
            return try await sessionRepository.thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }

    /// Releases decoded thumbnails without deleting either repository's encoded files.
    func releaseThumbnails() async {
        await sharedRepository.releaseThumbnails()
        await sessionRepository.releaseThumbnails()
    }
}

/// Actor-isolated catalogs, search, recents, and image access used by the keyboard model.
actor KeyboardDataStore: KeyboardDataProviding {
    private let applicationSupport: URL?
    private let loader = KeyboardCatalogLoader()
    private let searchIndex = SearchIndex()
    private let recentStore: RecentStore?
    private var frames: [CatalogFrame] = []
    private var recentIdentities: [FrameIdentity] = []
    private var imageProvider: KeyboardImageProvider?
    private var imagesAllowed = false

    /// Connects the store to the containing app's shared Application Support directory.
    init(applicationSupport: URL?) {
        self.applicationSupport = applicationSupport
        recentStore = applicationSupport.map {
            RecentStore(fileURL: $0.appendingPathComponent("recent.json"))
        }
    }

    /// Reloads app-owned catalogs, recents, and optional Full Access image services.
    func load(allowsImages: Bool) async throws -> KeyboardCatalogSnapshot {
        guard let applicationSupport, let recentStore else {
            throw KeyboardDataError.sharedContainerUnavailable
        }

        let nextImageProvider = allowsImages
            ? imageProvider ?? KeyboardImageProvider(applicationSupport: applicationSupport)
            : nil
        async let loadedFrames = loader.frames(in: applicationSupport)
        async let loadedRecents: Void = recentStore.load()
        try await nextImageProvider?.load()
        let nextFrames = try await loadedFrames
        try await loadedRecents
        try Task.checkCancellation()

        frames = nextFrames
        recentIdentities = await recentStore.all()
        imagesAllowed = allowsImages
        if let nextImageProvider { imageProvider = nextImageProvider }
        await searchIndex.replace(with: nextFrames)
        return KeyboardCatalogSnapshot(categories: Self.categories(in: nextFrames))
    }

    /// Returns recent frames for an empty query or ranked search results otherwise.
    func results(for query: String, category: CategoryKey?, limit: Int) async -> [CatalogFrame] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [CatalogFrame]
        if trimmed.isEmpty {
            matches = recentIdentities.compactMap { identity in
                frames.first { $0.identity == identity }
            }
        } else {
            matches = await searchIndex.search(
                trimmed,
                categoryIDs: category.map { [$0] } ?? []
            )
        }
        let filtered = category.map { selected in
            matches.filter { $0.categoryKey == selected }
        } ?? matches
        return Array(filtered.prefix(max(0, limit)))
    }

    /// Returns a compact image from the shared or session cache.
    func thumbnail(for frame: CatalogFrame, maxPixelSize: Int) async -> ImageThumbnail? {
        guard imagesAllowed, let imageProvider else { return nil }
        return try? await imageProvider.thumbnail(
            for: frame.imageURL,
            maxPixelSize: maxPixelSize
        )
    }

    /// Returns the original image required for copy, preview transfer, or drag.
    func asset(for url: URL) async throws -> ImageAsset {
        guard imagesAllowed, let imageProvider else { throw KeyboardDataError.imagesUnavailable }
        return try await imageProvider.asset(for: url)
    }

    /// Persists one successful image action and updates this process's recent ordering.
    func recordRecent(_ identity: FrameIdentity) async throws {
        guard let recentStore else { throw KeyboardDataError.sharedContainerUnavailable }
        try await recentStore.record(identity)
        recentIdentities = await recentStore.all()
    }

    /// Releases decoded thumbnails while preserving shared and temporary encoded files.
    func releaseImages() async {
        await imageProvider?.releaseThumbnails()
    }

    /// Builds a stable, duplicate-free category menu from frame order.
    private static func categories(in frames: [CatalogFrame]) -> [KeyboardCategoryOption] {
        var seen: Set<CategoryKey> = []
        return frames.compactMap { frame in
            guard seen.insert(frame.categoryKey).inserted else { return nil }
            return KeyboardCategoryOption(
                key: frame.categoryKey,
                name: frame.categoryName,
                sourceName: frame.sourceName
            )
        }
    }
}

/// Recoverable shared-data failures shown inside the keyboard.
enum KeyboardDataError: LocalizedError {
    case sharedContainerUnavailable
    case imagesUnavailable

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            "Open Tshunhue once before using the keyboard."
        case .imagesUnavailable:
            "Image Mode is not ready yet."
        }
    }
}
