import Foundation

actor RecentStore {
    private let fileURL: URL
    private var identities: [FrameIdentity] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        identities = try JSONDecoder().decode([FrameIdentity].self, from: Data(contentsOf: fileURL))
        identities = Array(identities.prefix(5))
    }

    func all() -> [FrameIdentity] { identities }

    func record(_ identity: FrameIdentity) throws {
        identities.removeAll { $0 == identity }
        identities.insert(identity, at: 0)
        identities = Array(identities.prefix(5))
        try persist()
    }

    func remove(_ identity: FrameIdentity) throws {
        identities.removeAll { $0 == identity }
        try persist()
    }

    func remove(categoryID: String, sourceURL: URL) throws {
        identities.removeAll { $0.categoryID == categoryID && $0.sourceURL == sourceURL }
        try persist()
    }

    func remove(sourceURL: URL) throws {
        identities.removeAll { $0.sourceURL == sourceURL }
        try persist()
    }

    func clear() throws {
        identities = []
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(identities).write(to: fileURL, options: .atomic)
    }
}
