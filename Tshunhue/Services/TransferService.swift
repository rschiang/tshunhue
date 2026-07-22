//
//  TransferService.swift
//  Tshunhue
//
//  Exports frames as JPEG data or files for copy, share, and drag operations.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// JPEG bytes and an optional cache file that can be exported without another write.
private struct PreparedJPEG: Sendable {
    /// JPEG bytes shared by file and data representations.
    let data: Data
    /// The existing cache file when the downloaded source was already JPEG.
    let cachedFileURL: URL?
}

/// Identifies a shared preparation task so a failed attempt cannot clear a later retry.
private struct JPEGPreparationTask {
    let id: UUID
    let task: Task<PreparedJPEG, Error>
}

/// Identifies a temporary-file task shared by repeated file representation requests.
private struct JPEGFileTask {
    let id: UUID
    let task: Task<URL, Error>
}

/// Coalesces transfer work and publishes one non-blocking recent-history update.
private actor FrameTransferPreparation {
    private let frame: CatalogFrame
    private let repository: ImageRepository
    private let recentStore: RecentStore
    private let onRecentChange: @Sendable () async -> Void
    private var preparationTask: JPEGPreparationTask?
    private var fileTask: JPEGFileTask?
    private var didPublishRecent = false

    /// Creates shared preparation state for one transferable value.
    init(
        frame: CatalogFrame,
        repository: ImageRepository,
        recentStore: RecentStore,
        onRecentChange: @escaping @Sendable () async -> Void
    ) {
        self.frame = frame
        self.repository = repository
        self.recentStore = recentStore
        self.onRecentChange = onRecentChange
    }

    /// Returns coalesced JPEG bytes and records the successful use asynchronously.
    func jpegData() async throws -> Data {
        let prepared = try await prepareJPEG()
        publishRecentOnce()
        return prepared.data
    }

    /// Returns an existing JPEG cache file or one coalesced converted temporary file.
    func jpegFileURL() async throws -> URL {
        let prepared = try await prepareJPEG()
        let url = try await prepareFile(for: prepared)
        publishRecentOnce()
        return url
    }

    /// Returns JPEG bytes for presentation without recording an outbound transfer.
    func previewJPEGData() async throws -> Data {
        try await prepareJPEG().data
    }

    /// Downloads and converts the image at most once for this transferable value.
    private func prepareJPEG() async throws -> PreparedJPEG {
        if let preparationTask { return try await preparationTask.task.value }
        let id = UUID()
        let frame = frame
        let repository = repository
        let task = Task {
            let asset = try await repository.asset(for: frame.imageURL)
            return PreparedJPEG(
                data: try JPEGEncoder.data(for: asset),
                cachedFileURL: asset.type.conforms(to: .jpeg) ? asset.localURL : nil
            )
        }
        preparationTask = JPEGPreparationTask(id: id, task: task)
        do {
            return try await task.value
        } catch {
            if preparationTask?.id == id { preparationTask = nil }
            throw error
        }
    }

    /// Reuses the source JPEG file or writes converted bytes once on demand.
    private func prepareFile(for prepared: PreparedJPEG) async throws -> URL {
        if let cachedFileURL = prepared.cachedFileURL { return cachedFileURL }
        if let fileTask { return try await fileTask.task.value }
        let id = UUID()
        let frame = frame
        let task = Task { try TransferService.exportJPEGFile(for: frame, data: prepared.data) }
        fileTask = JPEGFileTask(id: id, task: task)
        do {
            return try await task.value
        } catch {
            if fileTask?.id == id { fileTask = nil }
            throw error
        }
    }

    /// Starts ancillary recent-history work once without delaying the transfer provider.
    private func publishRecentOnce() {
        guard !didPublishRecent else { return }
        didPublishRecent = true
        let identity = frame.identity
        let recentStore = recentStore
        let onRecentChange = onRecentChange
        Task {
            do {
                try await recentStore.record(identity)
                await onRecentChange()
            } catch {
                // Recent history is ancillary and must never make a transfer fail.
            }
        }
    }
}

/// A lazily prepared JPEG transfer that records successful use in recents.
struct FrameTransferItem: Transferable, Sendable {
    /// A data-only JPEG representation used by the system share preview.
    struct PreviewImage: Transferable, Sendable {
        /// Supplies prepared JPEG bytes without exposing the cache file URL.
        let dataProvider: @Sendable () async throws -> Data

        /// Loads the preview bytes through the shared transfer preparation.
        func jpegData() async throws -> Data {
            try await dataProvider()
        }

        /// Provides concrete JPEG data to the share-sheet preview renderer.
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: .jpeg) { preview in
                try await preview.jpegData()
            }
        }
    }

    /// The frame whose image is exported.
    let frame: CatalogFrame
    /// Shared state used by every representation requested for this item.
    private let preparation: FrameTransferPreparation

    /// Creates a transferable frame with an optional recent-state notification.
    init(
        frame: CatalogFrame,
        repository: ImageRepository,
        recentStore: RecentStore,
        onRecentChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.frame = frame
        self.preparation = FrameTransferPreparation(
            frame: frame,
            repository: repository,
            recentStore: recentStore,
            onRecentChange: onRecentChange
        )
    }

    /// Downloads the source image and normalizes it to JPEG data.
    func jpegData() async throws -> Data {
        try await preparation.jpegData()
    }

    /// Returns a concrete JPEG file, reusing the cached file whenever possible.
    func jpegFileURL() async throws -> URL {
        try await preparation.jpegFileURL()
    }

    /// A JPEG preview that shares preparation but not file or recent-history behavior.
    var previewImage: PreviewImage {
        PreviewImage { try await preparation.previewJPEGData() }
    }

    /// Concrete JPEG file and data representations for destination compatibility.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { value in
            SentTransferredFile(try await value.jpegFileURL())
        }
        .suggestedFileName { value in
            TransferService.sanitizedFilename(value.frame.frame.caption) + ".jpg"
        }
        DataRepresentation(exportedContentType: .jpeg) { value in
            try await value.jpegData()
        }
    }
}

/// Main-actor pasteboard operations and platform-neutral temporary file export.
@MainActor
enum TransferService {
    /// Copies a normalized JPEG to the system pasteboard.
    static func copy(_ asset: ImageAsset) throws {
        let data = try JPEGEncoder.data(for: asset)
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) else {
            throw TransferError.cannotWritePasteboard
        }
        #elseif os(iOS)
        UIPasteboard.general.setData(data, forPasteboardType: UTType.jpeg.identifier)
        #endif
    }

    /// Writes JPEG data to a uniquely named temporary transfer file.
    nonisolated static func exportJPEGFile(for frame: CatalogFrame, data: Data) throws -> URL {
        let base = sanitizedFilename(frame.frame.caption)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tshunhue Transfers", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(base).appendingPathExtension("jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Converts a caption into a short, filesystem-safe export name.
    nonisolated static func sanitizedFilename(_ caption: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let parts = caption.components(separatedBy: invalid).joined(separator: " ")
        let joined = parts.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String((joined.isEmpty ? "Tshunhue" : joined).prefix(80))
    }
}

/// Failures produced by explicit copy operations.
enum TransferError: LocalizedError {
    case cannotWritePasteboard

    var errorDescription: String? {
        switch self {
        case .cannotWritePasteboard: "The JPEG could not be copied to the pasteboard."
        }
    }
}
