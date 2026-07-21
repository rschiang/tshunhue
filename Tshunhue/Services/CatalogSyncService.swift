import Foundation

actor CatalogSyncService {
    private let client: any HTTPFetching
    private let validator: CatalogValidator

    init(client: any HTTPFetching = HTTPClient(), validator: CatalogValidator = CatalogValidator()) {
        self.client = client
        self.validator = validator
    }

    func createSource(url: URL, isDefault: Bool) async throws -> SourceArchive {
        let result = try await client.get(url, byteLimit: CatalogLimits.indexBytes)
        guard let data = result.data else { throw SyncError.missingBody }
        _ = try validator.validateIndex(data: data, sourceURL: url)
        return SourceArchive(
            id: UUID(),
            sourceURL: canonical(url),
            isDefault: isDefault,
            index: CachedDocument(data: data, metadata: result.metadata),
            enabledCategoryIDs: [],
            categories: [:],
            lastSuccessfulRefresh: Date(),
            lastAttempt: Date(),
            refreshError: nil
        )
    }

    func setCategory(_ categoryID: String, enabled: Bool, in original: SourceArchive) async throws -> SourceArchive {
        var archive = original
        let index = try validator.validateIndex(data: archive.index.data, sourceURL: archive.sourceURL)
        guard let descriptor = index.categories.first(where: { $0.descriptor.id == categoryID }) else {
            throw SyncError.missingCategory(categoryID)
        }
        if enabled {
            let result = try await client.get(descriptor.url, byteLimit: CatalogLimits.categoryBytes)
            guard let data = result.data else { throw SyncError.missingBody }
            _ = try validator.validateCategory(
                data: data,
                documentURL: descriptor.url,
                descriptor: descriptor.descriptor,
                source: index
            )
            archive.enabledCategoryIDs.insert(categoryID)
            archive.categories[categoryID] = CachedDocument(data: data, metadata: result.metadata)
        } else {
            archive.enabledCategoryIDs.remove(categoryID)
            archive.categories.removeValue(forKey: categoryID)
        }
        archive.refreshError = nil
        return archive
    }

    func refresh(_ original: SourceArchive) async -> SourceArchive {
        var attempted = original
        attempted.lastAttempt = Date()
        do {
            let indexResult = try await client.get(
                original.sourceURL,
                validators: original.index.metadata,
                byteLimit: CatalogLimits.indexBytes
            )
            let indexData = indexResult.data ?? original.index.data
            let validatedIndex = try validator.validateIndex(data: indexData, sourceURL: original.sourceURL)
            var categoryDocuments: [String: CachedDocument] = [:]

            for categoryID in original.enabledCategoryIDs {
                guard let descriptor = validatedIndex.categories.first(where: { $0.descriptor.id == categoryID }) else {
                    throw SyncError.missingCategory(categoryID)
                }
                let oldDocument = original.categories[categoryID]
                let result = try await client.get(
                    descriptor.url,
                    validators: oldDocument?.metadata,
                    byteLimit: CatalogLimits.categoryBytes
                )
                let data = result.data ?? oldDocument?.data
                guard let data else { throw SyncError.missingBody }
                _ = try validator.validateCategory(
                    data: data,
                    documentURL: descriptor.url,
                    descriptor: descriptor.descriptor,
                    source: validatedIndex
                )
                categoryDocuments[categoryID] = CachedDocument(
                    data: data,
                    metadata: result.data == nil ? oldDocument?.metadata ?? result.metadata : result.metadata
                )
            }

            attempted.index = CachedDocument(
                data: indexData,
                metadata: indexResult.data == nil ? original.index.metadata : indexResult.metadata
            )
            attempted.categories = categoryDocuments
            attempted.lastSuccessfulRefresh = Date()
            attempted.refreshError = nil
        } catch {
            attempted = original
            attempted.lastAttempt = Date()
            attempted.refreshError = error.localizedDescription
        }
        return attempted
    }

    func validatedContents(of archive: SourceArchive) throws -> (Index, [CatalogFrame]) {
        let index = try validator.validateIndex(data: archive.index.data, sourceURL: archive.sourceURL)
        var frames: [CatalogFrame] = []
        for descriptor in index.categories where archive.enabledCategoryIDs.contains(descriptor.descriptor.id) {
            let categoryID = descriptor.descriptor.id
            guard let document = archive.categories[categoryID] else { continue }
            let category = try validator.validateCategory(
                data: document.data,
                documentURL: descriptor.url,
                descriptor: descriptor.descriptor,
                source: index
            )
            frames.append(contentsOf: category.frames)
        }
        return (index.index, frames)
    }

    func summary(of archive: SourceArchive) throws -> SourceSummary {
        let validated = try validator.validateIndex(data: archive.index.data, sourceURL: archive.sourceURL)
        return SourceSummary(
            id: archive.id,
            sourceURL: archive.sourceURL,
            name: validated.index.name,
            isDefault: archive.isDefault,
            categories: validated.index.categories,
            enabledCategoryIDs: archive.enabledCategoryIDs,
            lastSuccessfulRefresh: archive.lastSuccessfulRefresh,
            refreshError: archive.refreshError
        )
    }

    private func canonical(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        return components?.url ?? url
    }
}

enum SyncError: LocalizedError {
    case missingBody
    case missingCategory(String)

    var errorDescription: String? {
        switch self {
        case .missingBody: "The server returned no document."
        case .missingCategory(let id): "The source no longer contains category \(id)."
        }
    }
}
