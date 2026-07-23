//
//  SourceStore.swift
//  Tshunhue
//
//  Defines source persistence models and stores synchronized catalog archives.
//

import Foundation

/// The user's automatic catalog refresh interval.
enum RefreshFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case daily
    case weekly
    case monthly

    var id: Self { self }

    /// The interval in seconds, or `nil` for manual refreshes.
    var interval: TimeInterval? {
        switch self {
        case .manual: nil
        case .daily: 86_400
        case .weekly: 604_800
        case .monthly: 2_592_000
        }
    }

    /// The localized title shown in settings.
    var title: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        }
    }
}

/// A downloaded document paired with conditional-request metadata.
struct CachedDocument: Codable, Sendable {
    /// The last valid encoded document.
    var data: Data
    /// Validators and freshness metadata for conditional refreshes.
    var metadata: HTTPMetadata
}

/// The complete persisted state for one catalog source.
struct SourceArchive: Codable, Identifiable, Sendable {
    /// The local archive identifier.
    var id: UUID
    /// The canonical remote index URL.
    var sourceURL: URL
    /// Whether the source was supplied by the app bundle.
    var isDefault: Bool
    /// The last valid index document.
    var index: CachedDocument
    /// Categories selected by the user.
    var enabledCategoryIDs: Set<String>
    /// Last valid documents keyed by enabled category identifier.
    var categories: [String: CachedDocument]
    /// The most recent complete successful refresh.
    var lastSuccessfulRefresh: Date?
    /// The most recent refresh attempt.
    var lastAttempt: Date?
    /// A recoverable refresh failure shown in settings.
    var refreshError: String?
}

/// Lightweight source state presented by navigation and settings views.
struct SourceSummary: Identifiable, Hashable, Sendable {
    /// The local source identifier.
    let id: UUID
    /// The canonical remote index URL.
    let sourceURL: URL
    /// The source's validated display name.
    let name: String
    /// Whether the source is supplied by the app bundle.
    let isDefault: Bool
    /// Validated category descriptors from the index.
    let categories: [CategoryDescriptor]
    /// Category identifiers currently downloaded and searchable.
    let enabledCategoryIDs: Set<String>
    /// The most recent complete successful refresh.
    let lastSuccessfulRefresh: Date?
    /// A recoverable refresh failure shown in settings.
    let refreshError: String?
}

/// An actor-isolated store for independent source archive files.
actor SourceStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var archives: [UUID: SourceArchive] = [:]

    /// Creates a source store rooted at the supplied directory.
    init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Loads valid source archives while isolating damaged files.
    func load() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("source-") }
        var loaded: [UUID: SourceArchive] = [:]
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let archive = try decoder.decode(SourceArchive.self, from: data)
                loaded[archive.id] = archive
            } catch {
                // Isolate a damaged source archive so other configured sources remain usable.
                continue
            }
        }
        archives = loaded
    }

    /// Returns archives with defaults first and stable URL ordering.
    func allArchives() -> [SourceArchive] {
        archives.values.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.sourceURL.absoluteString < rhs.sourceURL.absoluteString
        }
    }

    /// Looks up an archive by its persisted identifier.
    func archive(id: UUID) -> SourceArchive? { archives[id] }

    /// Looks up an archive by canonical source URL.
    func archive(sourceURL: URL) -> SourceArchive? {
        archives.values.first { $0.sourceURL == sourceURL }
    }

    /// Atomically persists and updates an archive.
    func save(_ archive: SourceArchive) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(archive)
        try data.write(to: fileURL(for: archive.id), options: .atomic)
        archives[archive.id] = archive
    }

    /// Removes an archive from memory and disk.
    func remove(id: UUID) throws {
        guard let removed = archives.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: removed.id))
    }

    /// Returns the deterministic archive filename for a source identifier.
    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("source-\(id.uuidString).json")
    }
}
