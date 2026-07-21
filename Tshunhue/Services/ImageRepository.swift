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

/// An Objective-C-compatible wrapper used by `NSCache`.
private final class ThumbnailBox {
    /// The thumbnail retained by the cache.
    let image: CGImage
    /// Wraps a Core Graphics image for `NSCache` storage.
    init(_ image: CGImage) { self.image = image }
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
    /// The time the entry was most recently read.
    var lastAccess: Date
}

/// An actor-isolated image cache with request coalescing and LRU eviction.
actor ImageRepository {
    private let directory: URL
    private let indexURL: URL
    private let byteBudget: Int
    private let client: any HTTPFetching
    private var entries: [String: ImageCacheEntry] = [:]
    private var inFlight: [URL: Task<ImageAsset, Error>] = [:]
    private let thumbnails = NSCache<NSString, ThumbnailBox>()

    /// Creates a repository rooted at a cache directory with a fixed byte budget.
    init(directory: URL, byteBudget: Int, client: any HTTPFetching = HTTPClient()) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.byteBudget = byteBudget
        self.client = client
    }

    /// Loads the cache index, repairs corruption, and enforces the byte budget.
    func load() throws {
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
            try persistIndex()
        }
        try discardMissingFiles()
        try evictIfNeeded()
    }

    /// Returns a cached or freshly downloaded validated image.
    func asset(for url: URL) async throws -> ImageAsset {
        if let task = inFlight[url] { return try await task.value }
        let task = Task { try await self.loadAsset(for: url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
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
        return ImageThumbnail(image: thumbnail)
    }

    /// The total number of image bytes tracked by the cache index.
    func cacheSize() -> Int { entries.values.reduce(0) { $0 + $1.byteCount } }

    /// Cancels active loads and removes every cached image.
    func clear() throws {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        for entry in entries.values {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
        }
        entries = [:]
        thumbnails.removeAllObjects()
        try persistIndex()
    }

    // MARK: - Loading and Validation

    /// Resolves an image from fresh cache, conditional refresh, or a new download.
    private func loadAsset(for url: URL) async throws -> ImageAsset {
        let key = cacheKey(for: url)
        if var entry = entries[key] {
            let fileURL = directory.appendingPathComponent(entry.filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if isFresh(entry) {
                    entry.lastAccess = Date()
                    entries[key] = entry
                    try? persistIndex()
                    return try read(entry, fileURL: fileURL)
                }
                do {
                    let result = try await client.get(
                        url,
                        validators: entry.metadata,
                        byteLimit: CatalogLimits.imageBytes
                    )
                    if result.data == nil {
                        entry.metadata = merged(result.metadata, fallback: entry.metadata)
                        entry.lastAccess = Date()
                        entries[key] = entry
                        try persistIndex()
                        return try read(entry, fileURL: fileURL)
                    }
                    try Task.checkCancellation()
                    return try store(result.data!, from: url, metadata: result.metadata, key: key)
                } catch {
                    entry.lastAccess = Date()
                    entries[key] = entry
                    return try read(entry, fileURL: fileURL)
                }
            }
            entries[key] = nil
        }

        let result = try await client.get(url, byteLimit: CatalogLimits.imageBytes)
        guard let data = result.data else { throw ImageRepositoryError.missingData }
        try Task.checkCancellation()
        return try store(data, from: url, metadata: result.metadata, key: key)
    }

    /// Validates and atomically stores downloaded image data.
    private func store(_ data: Data, from url: URL, metadata: HTTPMetadata, key: String) throws -> ImageAsset {
        let properties = try inspect(data)
        let filename = key + ".image"
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        entries[key] = ImageCacheEntry(
            key: key,
            sourceURL: url,
            filename: filename,
            typeIdentifier: properties.type.identifier,
            width: properties.width,
            height: properties.height,
            byteCount: data.count,
            metadata: metadata,
            downloadedAt: Date(),
            lastAccess: Date()
        )
        try evictIfNeeded(excluding: key)
        try persistIndex()
        return ImageAsset(
            data: data,
            type: properties.type,
            width: properties.width,
            height: properties.height,
            localURL: fileURL
        )
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

    /// Determines freshness from HTTP expiration or the one-week fallback lifetime.
    private func isFresh(_ entry: ImageCacheEntry) -> Bool {
        let expiry = entry.metadata.expires ?? entry.downloadedAt.addingTimeInterval(604_800)
        return expiry > Date()
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
        try persistIndex()
    }

    /// Evicts least-recently-used images until the byte budget is met.
    private func evictIfNeeded(excluding protectedKey: String? = nil) throws {
        var total = cacheSize()
        for entry in entries.values.sorted(by: { $0.lastAccess < $1.lastAccess })
        where total > byteBudget && entry.key != protectedKey {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
            entries[entry.key] = nil
            total -= entry.byteCount
        }
    }

    /// Atomically writes a deterministic cache-index document.
    private func persistIndex() throws {
        let data = try JSONEncoder().encode(entries.values.sorted { $0.key < $1.key })
        try data.write(to: indexURL, options: .atomic)
    }
}

/// Failures produced while loading and inspecting images.
enum ImageRepositoryError: LocalizedError {
    case missingData
    case cannotDecode
    case tooManyPixels

    var errorDescription: String? {
        switch self {
        case .missingData: "The image server returned no data."
        case .cannotDecode: "The file is not a supported static image."
        case .tooManyPixels: "The image exceeds the pixel limit."
        }
    }
}
