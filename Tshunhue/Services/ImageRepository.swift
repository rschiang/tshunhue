import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageAsset: Sendable {
    let data: Data
    let type: UTType
    let width: Int
    let height: Int
    let localURL: URL
}

struct ImageThumbnail: @unchecked Sendable {
    let image: CGImage
}

private final class ThumbnailBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private struct ImageCacheEntry: Codable, Sendable {
    let key: String
    let sourceURL: URL
    let filename: String
    var typeIdentifier: String
    var width: Int
    var height: Int
    var byteCount: Int
    var metadata: HTTPMetadata
    var downloadedAt: Date
    var lastAccess: Date
}

actor ImageRepository {
    private let directory: URL
    private let indexURL: URL
    private let byteBudget: Int
    private let client: any HTTPFetching
    private var entries: [String: ImageCacheEntry] = [:]
    private var inFlight: [URL: Task<ImageAsset, Error>] = [:]
    private let thumbnails = NSCache<NSString, ThumbnailBox>()

    init(directory: URL, byteBudget: Int, client: any HTTPFetching = HTTPClient()) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.byteBudget = byteBudget
        self.client = client
    }

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

    func asset(for url: URL) async throws -> ImageAsset {
        if let task = inFlight[url] { return try await task.value }
        let task = Task { try await self.loadAsset(for: url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }

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

    func cacheSize() -> Int { entries.values.reduce(0) { $0 + $1.byteCount } }

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

    private func isFresh(_ entry: ImageCacheEntry) -> Bool {
        let expiry = entry.metadata.expires ?? entry.downloadedAt.addingTimeInterval(604_800)
        return expiry > Date()
    }

    private func merged(_ metadata: HTTPMetadata, fallback: HTTPMetadata) -> HTTPMetadata {
        HTTPMetadata(
            etag: metadata.etag ?? fallback.etag,
            lastModified: metadata.lastModified ?? fallback.lastModified,
            expires: metadata.expires ?? fallback.expires
        )
    }

    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func discardMissingFiles() throws {
        entries = entries.filter { _, entry in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.filename).path)
        }
        try persistIndex()
    }

    private func evictIfNeeded(excluding protectedKey: String? = nil) throws {
        var total = cacheSize()
        for entry in entries.values.sorted(by: { $0.lastAccess < $1.lastAccess })
        where total > byteBudget && entry.key != protectedKey {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.filename))
            entries[entry.key] = nil
            total -= entry.byteCount
        }
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(entries.values.sorted { $0.key < $1.key })
        try data.write(to: indexURL, options: .atomic)
    }
}

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
