import Foundation

enum RefreshFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case daily
    case weekly
    case monthly

    var id: Self { self }

    var interval: TimeInterval? {
        switch self {
        case .manual: nil
        case .daily: 86_400
        case .weekly: 604_800
        case .monthly: 2_592_000
        }
    }

    var title: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        }
    }
}

struct CachedDocument: Codable, Sendable {
    var data: Data
    var metadata: HTTPMetadata
}

struct SourceArchive: Codable, Identifiable, Sendable {
    var id: UUID
    var sourceURL: URL
    var isDefault: Bool
    var index: CachedDocument
    var enabledCategoryIDs: Set<String>
    var categories: [String: CachedDocument]
    var lastSuccessfulRefresh: Date?
    var lastAttempt: Date?
    var refreshError: String?
}

struct SourceSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let name: String
    let isDefault: Bool
    let categories: [CategoryDescriptor]
    let enabledCategoryIDs: Set<String>
    let lastSuccessfulRefresh: Date?
    let refreshError: String?
}

actor SourceStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var archives: [UUID: SourceArchive] = [:]

    init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

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

    func allArchives() -> [SourceArchive] {
        archives.values.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.sourceURL.absoluteString < rhs.sourceURL.absoluteString
        }
    }

    func archive(id: UUID) -> SourceArchive? { archives[id] }

    func archive(sourceURL: URL) -> SourceArchive? {
        archives.values.first { $0.sourceURL == sourceURL }
    }

    func save(_ archive: SourceArchive) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(archive)
        try data.write(to: fileURL(for: archive.id), options: .atomic)
        archives[archive.id] = archive
    }

    func remove(id: UUID) throws {
        guard let removed = archives.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: removed.id))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("source-\(id.uuidString).json")
    }
}
