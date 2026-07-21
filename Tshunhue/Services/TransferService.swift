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

/// A lazily prepared JPEG transfer that records successful use in recents.
struct FrameTransferItem: Transferable, Sendable {
    /// The frame whose image is exported.
    let frame: CatalogFrame
    /// The repository supplying validated source bytes.
    let repository: ImageRepository
    /// The store updated after transfer preparation succeeds.
    let recentStore: RecentStore

    /// Downloads the source image and normalizes it to JPEG data.
    func jpegData() async throws -> Data {
        let asset = try await repository.asset(for: frame.imageURL)
        return try JPEGEncoder.data(for: asset)
    }

    /// Concrete JPEG file and data representations for destination compatibility.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { value in
            let data = try await value.jpegData()
            let url = try TransferService.exportJPEGFile(for: value.frame, data: data)
            try await value.recentStore.record(value.frame.identity)
            return SentTransferredFile(url)
        }
        DataRepresentation(exportedContentType: .jpeg) { value in
            let data = try await value.jpegData()
            try await value.recentStore.record(value.frame.identity)
            return data
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
