//
//  ImageRepository.swift
//  Tshunhue
//
//  Downloads, validates, caches, and thumbnails reaction images.
//

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A validated image together with its format, dimensions, and cache location.
struct ImageAsset: Sendable {
    /// Original encoded image bytes.
    let data: Data
    /// The detected uniform type of the bytes.
    let type: UTType
    /// Decoded pixel width before display transforms.
    let width: Int
    /// Decoded pixel height before display transforms.
    let height: Int
    /// The file containing the cached encoded bytes.
    let localURL: URL
}

/// A display-ready thumbnail safe to pass across isolation boundaries.
struct ImageThumbnail: @unchecked Sendable {
    /// The immutable Core Graphics image rendered by SwiftUI or UIKit.
    let image: CGImage
}

/// Controls whether an image repository may mutate its on-disk cache.
enum ImageRepositoryAccess: Sendable, Equatable {
    case readWrite
    case readOnly
}

/// An Objective-C-compatible wrapper used by `NSCache`.
private final class ThumbnailBox {
    /// The thumbnail retained by the cache.
    let image: CGImage
    /// Wraps a Core Graphics image for `NSCache` storage.
    init(_ image: CGImage) { self.image = image }
}

/// Identifies a blocking first-download task so late cleanup cannot remove a replacement.
private struct AssetLoadTask {
    let id: UUID
    let task: Task<ImageAsset, Error>
}

/// Identifies a background refresh so cancellation remains safe across cache clearing.
private struct ImageRefreshTask {
    let id: UUID
    let task: Task<Void, Never>
}

/// Persisted metadata for one cached image file.
private struct ImageCacheEntry: Codable, Sendable {
    /// The SHA-256 cache key.
    let key: String
    /// The original remote image URL.
    let sourceURL: URL
    /// The cache-relative image filename.
    let filename: String
    /// The detected uniform type identifier.
    var typeIdentifier: String
    /// The decoded pixel width.
    var width: Int
    /// The decoded pixel height.
    var height: Int
    /// The encoded file size used for budget accounting.
    var byteCount: Int
    /// Conditional-request and freshness metadata.
    var metadata: HTTPMetadata
    /// The time the current bytes were downloaded.
    var downloadedAt: Date
    /// The latest background revalidation attempt, successful or otherwise.
    var lastRevalidationAttempt: Date?
    /// The time the entry was most recently read.
    var lastAccess: Date
}

/// An actor-isolated image cache with request coalescing and LRU eviction.
actor ImageRepository {
    /// Cached images are reconsidered for refresh at most once per week.
    private static let revalidationInterval: TimeInterval = 604_800
    /// Access-only index changes are coalesced away from image delivery.
    private static let accessPersistenceDelay: UInt64 = 1_000_000_000

    private let directory: URL
    private let indexURL: URL
    private let byteBudget: Int
    private let access: ImageRepositoryAccess
    private let client: any HTTPFetching
    private let now: @Sendable () -> Date
    private var entries: [String: ImageCacheEntry] = [:]
    private var inFlight: [URL: AssetLoadTask] = [:]
    private var refreshTasks: [URL: ImageRefreshTask] = [:]
    private var accessPersistenceTask: Task<Void, Never>?
    private let thumbnails = NSCache<NSString, ThumbnailBox>()
    private var thumbnailKeysByURL: [URL: Set<NSString>] = [:]

    /// Creates a repository rooted at a cache directory with a fixed byte budget.
    init(
        directory: URL,
        byteBudget: Int,
        access: ImageRepositoryAccess = .readWrite,
        client: any HTTPFetching = HTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.byteBudget = byteBudget
        self.access = access
        self.client = client
        self.now = now
    }

    /// Loads the cache index, repairs corruption, and enforces the byte budget.
    func load() throws {
        if access == .readOnly {
            guard FileManager.default.fileExists(atPath: indexURL.path) else {
                entries = [:]
                return
            }
            guard let decoded = try? JSONDecoder().decode(
                [ImageCacheEntry].self,
                from: Data(contentsOf: indexURL)
            ) else {
                entries = [:]
                return
            }
            entries = Dictionary(uniqueKeysWithValues: decoded.compactMap { entry in
                let fileURL = directory.appendingPathComponent(entry.filename)
                return FileManager.default.fileExists(atPath: fileURL.path) ? (entry.key, entry) : nil
            })
            return
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let decoded = try JSONDecoder().decode([ImageCacheEntry].self, from: Data(contentsOf: indexURL))
            entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.key, $0) })
        } catch {
            entries = [:]
            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) where url.pathExtension == "image" {
                try? FileManager.default.removeItem(at: url)
            }
            try persistIndexNow()
        }
        try discardMissingFiles()
        try evictIfNeeded()
        try persistIndexNow()
    }

    /// Returns a cached or freshly downloaded validated image.
    func asset(for url: URL) async throws -> ImageAsset {
        if let request = inFlight[url] { return try await request.task.value }
        let id = UUID()
        let task = Task { try await self.loadAsset(for: url) }
        inFlight[url] = AssetLoadTask(id: id, task: task)
        defer {
            if inFlight[url]?.id == id { inFlight[url] = nil }
        }
        return try await task.value
    }

    /// Returns a transformed thumbnail no larger than the requested pixel dimension.
    func thumbnail(for url: URL, maxPixelSize: Int) async throws -> ImageThumbnail {
        let thumbnailKey = "\(url.absoluteString)#\(maxPixelSize)" as NSString
        if let cached = thumbnails.object(forKey: thumbnailKey) {
            return ImageThumbnail(image: cached.image)
        }
        let asset = try await asset(for: url)
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else {
            throw ImageRepositoryError.cannotDecode
        }
        thumbnails.setObject(ThumbnailBox(thumbnail), forKey: thumbnailKey)
        thumbnailKeysByURL[url, default: []].insert(thumbnailKey)
        return ImageThumbnail(image: thumbnail)
    }

    /// The total number of image bytes tracked by the cache index.
    func cacheSize() -> Int { entries.values.reduce(0) { $0 + $1.byteCount } }

    /// Releases decoded thumbnails while preserving original cached image files.
    func releaseThumbnails() {
        thumbnails.removeAllObjects()
        thumbnailKeysByURL = [:]
    }

    /// Cancels active loads and removes every cached image.
    func clear() throws {
        guard access == .readWrite else { throw ImageRepositoryError.readOnly }
        for request in inFlight.values { request.task.cancel() }
        for refresh in refreshTasks.values { refresh.task.cancel() }
        accessPersistenceTask?.cancel()
        inFlight = [:]
        refreshTasks = [:]
        accessPersistenceTask = nil
        for entry in entries.values {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
        }
        entries = [:]
        thumbnails.removeAllObjects()
        thumbnailKeysByURL = [:]
        try persistIndexNow()
    }

    // MARK: - Loading and Validation

    /// Resolves an image from local cache immediately or performs a required first download.
    private func loadAsset(for url: URL) async throws -> ImageAsset {
        let key = cacheKey(for: url)
        if var entry = entries[key] {
            let fileURL = directory.appendingPathComponent(entry.filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if access == .readOnly {
                    return try read(entry, fileURL: fileURL)
                }
                let accessDate = now()
                entry.lastAccess = accessDate
                entries[key] = entry
                scheduleAccessPersistence()
                if shouldRevalidate(entry, at: accessDate) {
                    scheduleRevalidation(for: url, key: key)
                }
                return try read(entry, fileURL: fileURL)
            }
            entries[key] = nil
            if access == .readWrite { try persistIndexNow() }
        }

        guard access == .readWrite else { throw ImageRepositoryError.notCached }
        let result = try await client.get(url, byteLimit: CatalogLimits.imageBytes)
        guard let data = result.data else { throw ImageRepositoryError.missingData }
        try Task.checkCancellation()
        return try store(data, from: url, metadata: result.metadata, key: key)
    }

    /// Starts one non-blocking conditional refresh for a stale cached image.
    private func scheduleRevalidation(for url: URL, key: String) {
        guard refreshTasks[url] == nil else { return }
        let id = UUID()
        let task = Task { await self.revalidateCachedAsset(for: url, key: key, taskID: id) }
        refreshTasks[url] = ImageRefreshTask(id: id, task: task)
    }

    /// Refreshes cached bytes while preserving the last valid local image on any failure.
    private func revalidateCachedAsset(for url: URL, key: String, taskID: UUID) async {
        defer {
            if refreshTasks[url]?.id == taskID { refreshTasks[url] = nil }
        }
        guard let original = entries[key], original.sourceURL == url else { return }
        let fileURL = directory.appendingPathComponent(original.filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let attemptDate = now()

        do {
            let result = try await client.get(
                url,
                validators: original.metadata,
                byteLimit: CatalogLimits.imageBytes
            )
            try Task.checkCancellation()
            guard let current = entries[key],
                  current.filename == original.filename,
                  current.downloadedAt == original.downloadedAt else { return }

            if let data = result.data {
                _ = try store(data, from: url, metadata: result.metadata, key: key)
            } else {
                var revalidated = current
                revalidated.metadata = merged(result.metadata, fallback: current.metadata)
                revalidated.lastRevalidationAttempt = attemptDate
                entries[key] = revalidated
                try persistIndexNow()
            }
        } catch {
            guard !Task.isCancelled,
                  var current = entries[key],
                  current.filename == original.filename,
                  current.downloadedAt == original.downloadedAt else { return }
            // A failed refresh must not cause a network request on every image access.
            current.lastRevalidationAttempt = attemptDate
            entries[key] = current
            try? persistIndexNow()
        }
    }

    /// Validates and atomically stores downloaded image data.
    private func store(_ data: Data, from url: URL, metadata: HTTPMetadata, key: String) throws -> ImageAsset {
        let properties = try inspect(data)
        let filename = key + "." + filenameExtension(for: properties.type, sourceURL: url)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        let previousFilename = entries[key]?.filename
        let date = now()
        entries[key] = ImageCacheEntry(
            key: key,
            sourceURL: url,
            filename: filename,
            typeIdentifier: properties.type.identifier,
            width: properties.width,
            height: properties.height,
            byteCount: data.count,
            metadata: metadata,
            downloadedAt: date,
            lastRevalidationAttempt: nil,
            lastAccess: date
        )
        if let previousFilename, previousFilename != filename {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previousFilename))
        }
        invalidateThumbnails(for: url)
        try evictIfNeeded(excluding: key)
        try persistIndexNow()
        return ImageAsset(
            data: data,
            type: properties.type,
            width: properties.width,
            height: properties.height,
            localURL: fileURL
        )
    }

    /// Chooses a useful cache suffix from validated bytes, the source URL, or JPEG as a fallback.
    private func filenameExtension(for type: UTType, sourceURL: URL) -> String {
        if let preferredExtension = type.preferredFilenameExtension, !preferredExtension.isEmpty {
            return preferredExtension.lowercased()
        }
        let sourceExtension = sourceURL.pathExtension
        return sourceExtension.isEmpty ? "jpg" : sourceExtension.lowercased()
    }

    /// Recreates an image asset from persisted metadata and bytes.
    private func read(_ entry: ImageCacheEntry, fileURL: URL) throws -> ImageAsset {
        guard let type = UTType(entry.typeIdentifier) else { throw ImageRepositoryError.cannotDecode }
        return ImageAsset(
            data: try Data(contentsOf: fileURL, options: .mappedIfSafe),
            type: type,
            width: entry.width,
            height: entry.height,
            localURL: fileURL
        )
    }

    /// Verifies a single static image and returns its format and dimensions.
    private func inspect(_ data: Data) throws -> (type: UTType, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ImageRepositoryError.cannotDecode
        }
        guard Int64(width) * Int64(height) <= Int64(CatalogLimits.imagePixels) else {
            throw ImageRepositoryError.tooManyPixels
        }
        return (type, width, height)
    }

    // MARK: - Cache Maintenance

    /// Determines whether the local image has reached its weekly refresh checkpoint.
    private func shouldRevalidate(_ entry: ImageCacheEntry, at date: Date) -> Bool {
        let checkpoint = entry.lastRevalidationAttempt ?? entry.downloadedAt
        return date.timeIntervalSince(checkpoint) >= Self.revalidationInterval
    }

    /// Fills missing response metadata from a previous cache entry.
    private func merged(_ metadata: HTTPMetadata, fallback: HTTPMetadata) -> HTTPMetadata {
        HTTPMetadata(
            etag: metadata.etag ?? fallback.etag,
            lastModified: metadata.lastModified ?? fallback.lastModified,
            expires: metadata.expires ?? fallback.expires
        )
    }

    /// Hashes a source URL into a filesystem-safe stable cache key.
    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Removes index entries whose image files no longer exist.
    private func discardMissingFiles() throws {
        entries = entries.filter { _, entry in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.filename).path)
        }
        try persistIndexNow()
    }

    /// Evicts least-recently-used images until the byte budget is met.
    private func evictIfNeeded(excluding protectedKey: String? = nil) throws {
        var total = cacheSize()
        for entry in entries.values.sorted(by: { $0.lastAccess < $1.lastAccess })
        where total > byteBudget && entry.key != protectedKey {
            refreshTasks[entry.sourceURL]?.task.cancel()
            refreshTasks[entry.sourceURL] = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
            entries[entry.key] = nil
            invalidateThumbnails(for: entry.sourceURL)
            total -= entry.byteCount
        }
    }

    /// Removes every in-memory thumbnail derived from one source image.
    private func invalidateThumbnails(for url: URL) {
        for key in thumbnailKeysByURL.removeValue(forKey: url) ?? [] {
            thumbnails.removeObject(forKey: key)
        }
    }

    /// Defers access-only metadata writes so image delivery does not wait for disk I/O.
    private func scheduleAccessPersistence() {
        guard accessPersistenceTask == nil else { return }
        accessPersistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.accessPersistenceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.persistAccessChanges()
        }
    }

    /// Writes coalesced access timestamps without surfacing cache-maintenance errors.
    private func persistAccessChanges() {
        accessPersistenceTask = nil
        try? writeIndex()
    }

    /// Cancels a deferred access write and immediately persists structural changes.
    private func persistIndexNow() throws {
        accessPersistenceTask?.cancel()
        accessPersistenceTask = nil
        try writeIndex()
    }

    /// Atomically writes a deterministic cache-index document.
    private func writeIndex() throws {
        let data = try JSONEncoder().encode(entries.values.sorted { $0.key < $1.key })
        try data.write(to: indexURL, options: .atomic)
    }
}

/// Failures produced while loading and inspecting images.
enum ImageRepositoryError: LocalizedError {
    case notCached
    case readOnly
    case missingData
    case cannotDecode
    case tooManyPixels

    var errorDescription: String? {
        switch self {
        case .notCached: "The image is not available in the shared cache."
        case .readOnly: "The shared image cache is read-only."
        case .missingData: "The image server returned no data."
        case .cannotDecode: "The file is not a supported static image."
        case .tooManyPixels: "The image exceeds the pixel limit."
        }
    }
}
