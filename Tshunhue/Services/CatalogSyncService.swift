//
//  CatalogSyncService.swift
//  Tshunhue
//
//  Downloads, validates, and refreshes persisted catalog sources.
//

import Foundation

/// Serializes source synchronization and preserves the last valid archive on refresh failures.
actor CatalogSyncService {
    private let client: any HTTPFetching
    private let validator: CatalogValidator
    private let now: @Sendable () -> Date

    /// Creates a sync service with injectable networking and validation dependencies.
    init(
        client: any HTTPFetching = HTTPClient(),
        validator: CatalogValidator = CatalogValidator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.validator = validator
        self.now = now
    }

    /// Downloads and validates a new source index without enabling categories.
    func createSource(url: URL, isDefault: Bool) async throws -> SourceArchive {
        let result = try await client.get(url, byteLimit: CatalogLimits.indexBytes)
        guard let data = result.data else { throw SyncError.missingBody }
        _ = try validator.validateIndex(data: data, sourceURL: url)
        let date = now()
        return SourceArchive(
            id: UUID(),
            sourceURL: canonical(url),
            isDefault: isDefault,
            index: CachedDocument(data: data, metadata: result.metadata, validatedAt: date),
            enabledCategoryIDs: [],
            categories: [:],
            lastSuccessfulRefresh: date,
            lastAttempt: date,
            refreshError: nil
        )
    }

    /// Enables and downloads a category, or disables it while retaining its metadata.
    func setCategory(_ categoryID: String, enabled: Bool, in original: SourceArchive) async throws -> SourceArchive {
        var archive = original
        if enabled {
            let document = try await downloadCategoryDocument(categoryID, in: archive)
            archive.enabledCategoryIDs.insert(categoryID)
            archive.categories[categoryID] = document
        } else {
            archive.enabledCategoryIDs.remove(categoryID)
        }
        archive.refreshError = nil
        return archive
    }

    /// Returns a locally valid category document when its freshness window is still open.
    func freshCachedCategoryDocument(
        _ categoryID: String,
        in archive: SourceArchive,
        refreshFrequency: RefreshFrequency
    ) throws -> CachedDocument? {
        let (index, descriptor) = try categoryDescriptor(categoryID, in: archive)
        guard let document = archive.categories[categoryID],
              document.isFresh(at: now(), refreshFrequency: refreshFrequency) else { return nil }
        do {
            _ = try validator.validateCategory(
                data: document.data,
                documentURL: descriptor.url,
                descriptor: descriptor.descriptor,
                source: index
            )
            return document
        } catch {
            return nil
        }
    }

    /// Downloads and validates a category without sending validators from an expired entry.
    func downloadCategoryDocument(_ categoryID: String, in archive: SourceArchive) async throws -> CachedDocument {
        let (index, descriptor) = try categoryDescriptor(categoryID, in: archive)
        let result = try await client.get(descriptor.url, byteLimit: CatalogLimits.categoryBytes)
        guard let data = result.data else { throw SyncError.missingBody }
        _ = try validator.validateCategory(
            data: data,
            documentURL: descriptor.url,
            descriptor: descriptor.descriptor,
            source: index
        )
        return CachedDocument(data: data, metadata: result.metadata, validatedAt: now())
    }

    /// Removes stale disabled manifests while retaining every enabled last-known-good document.
    func pruneDisabledCache(
        in original: SourceArchive,
        refreshFrequency: RefreshFrequency
    ) throws -> SourceArchive {
        var archive = original
        let index = try validator.validateIndex(data: archive.index.data, sourceURL: archive.sourceURL)
        let validIDs = Set(index.categories.map(\.descriptor.id))
        archive.enabledCategoryIDs.formIntersection(validIDs)
        archive.categories = archive.categories.filter { categoryID, document in
            guard validIDs.contains(categoryID) else { return false }
            return archive.enabledCategoryIDs.contains(categoryID)
                || document.isFresh(at: now(), refreshFrequency: refreshFrequency)
        }
        return archive
    }

    /// Conditionally refreshes one archive while retaining its last valid data on failure.
    func refresh(_ original: SourceArchive, refreshFrequency: RefreshFrequency = .weekly) async -> SourceArchive {
        var attempted = original
        let attemptDate = now()
        attempted.lastAttempt = attemptDate
        do {
            let previousIndex = try validator.validateIndex(
                data: original.index.data,
                sourceURL: original.sourceURL
            )
            let indexResult = try await client.get(
                original.sourceURL,
                validators: original.index.metadata,
                byteLimit: CatalogLimits.indexBytes
            )
            let indexData = indexResult.data ?? original.index.data
            let validatedIndex = try validator.validateIndex(data: indexData, sourceURL: original.sourceURL)
            let previousDescriptors = Dictionary(
                uniqueKeysWithValues: previousIndex.categories.map { ($0.descriptor.id, $0.url) }
            )
            let nextDescriptors = Dictionary(
                uniqueKeysWithValues: validatedIndex.categories.map { ($0.descriptor.id, $0.url) }
            )
            let nextEnabledIDs = original.enabledCategoryIDs.intersection(nextDescriptors.keys)
            var categoryDocuments = original.categories.filter { categoryID, document in
                guard let nextURL = nextDescriptors[categoryID],
                      previousDescriptors[categoryID] == nextURL else { return false }
                return nextEnabledIDs.contains(categoryID)
                    || document.isFresh(at: attemptDate, refreshFrequency: refreshFrequency)
            }

            for descriptor in validatedIndex.categories where nextEnabledIDs.contains(descriptor.descriptor.id) {
                let categoryID = descriptor.descriptor.id
                let oldDocument = previousDescriptors[categoryID] == descriptor.url
                    ? original.categories[categoryID]
                    : nil
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
                    metadata: result.data == nil
                        ? merged(result.metadata, fallback: oldDocument?.metadata, at: attemptDate)
                        : result.metadata,
                    validatedAt: attemptDate
                )
            }

            attempted.index = CachedDocument(
                data: indexData,
                metadata: indexResult.data == nil
                    ? merged(indexResult.metadata, fallback: original.index.metadata, at: attemptDate)
                    : indexResult.metadata,
                validatedAt: attemptDate
            )
            attempted.enabledCategoryIDs = nextEnabledIDs
            attempted.categories = categoryDocuments
            attempted.lastSuccessfulRefresh = attemptDate
            attempted.refreshError = nil
        } catch {
            attempted = original
            attempted.lastAttempt = attemptDate
            attempted.refreshError = error.localizedDescription
        }
        return attempted
    }

    /// Revalidates an archive and returns its index plus enabled frames.
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

    /// Produces lightweight source state for settings and browse navigation.
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

    /// Normalizes a source URL before persistence.
    private func canonical(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        return components?.url ?? url
    }

    /// Resolves one category descriptor against the archive's current validated index.
    private func categoryDescriptor(
        _ categoryID: String,
        in archive: SourceArchive
    ) throws -> (ValidatedIndex, (descriptor: CategoryDescriptor, url: URL)) {
        let index = try validator.validateIndex(data: archive.index.data, sourceURL: archive.sourceURL)
        guard let descriptor = index.categories.first(where: { $0.descriptor.id == categoryID }) else {
            throw SyncError.missingCategory(categoryID)
        }
        return (index, descriptor)
    }

    /// Carries forward validators while resetting an already-expired explicit deadline.
    private func merged(_ metadata: HTTPMetadata, fallback: HTTPMetadata?, at date: Date) -> HTTPMetadata {
        HTTPMetadata(
            etag: metadata.etag ?? fallback?.etag,
            lastModified: metadata.lastModified ?? fallback?.lastModified,
            expires: metadata.expires ?? fallback?.expires.flatMap { $0 > date ? $0 : nil }
        )
    }
}

/// Failures specific to synchronizing catalog documents.
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
