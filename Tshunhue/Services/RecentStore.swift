//
//  RecentStore.swift
//  Tshunhue
//
//  Persists the small ordered list of recently transferred frames.
//

import Foundation

/// An actor-isolated, five-item most-recently-used frame store.
actor RecentStore {
    private let fileURL: URL
    private var identities: [FrameIdentity] = []

    /// Creates a recent store backed by the supplied JSON file.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads and trims persisted identities.
    func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        identities = try JSONDecoder().decode([FrameIdentity].self, from: Data(contentsOf: fileURL))
        identities = Array(identities.prefix(5))
    }

    /// Returns recent identities in newest-first order.
    func all() -> [FrameIdentity] { identities }

    /// Promotes an identity to the front and persists the bounded list.
    func record(_ identity: FrameIdentity) throws {
        identities.removeAll { $0 == identity }
        identities.insert(identity, at: 0)
        identities = Array(identities.prefix(5))
        try persist()
    }

    /// Removes one frame identity.
    func remove(_ identity: FrameIdentity) throws {
        identities.removeAll { $0 == identity }
        try persist()
    }

    /// Removes identities belonging to one source category.
    func remove(categoryID: String, sourceURL: URL) throws {
        identities.removeAll { $0.categoryID == categoryID && $0.sourceURL == sourceURL }
        try persist()
    }

    /// Removes identities belonging to one source.
    func remove(sourceURL: URL) throws {
        identities.removeAll { $0.sourceURL == sourceURL }
        try persist()
    }

    /// Removes all recent identities.
    func clear() throws {
        identities = []
        try persist()
    }

    /// Writes the current list atomically, creating its parent directory as needed.
    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(identities).write(to: fileURL, options: .atomic)
    }
}
