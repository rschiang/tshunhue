import CoreTransferable
import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct FrameTransferItem: Transferable, Sendable {
    let frame: CatalogFrame
    let repository: ImageRepository
    let recentStore: RecentStore

    func jpegData() async throws -> Data {
        let asset = try await repository.asset(for: frame.imageURL)
        return try JPEGEncoder.data(for: asset)
    }

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

@MainActor
enum TransferService {
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

    nonisolated static func sanitizedFilename(_ caption: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let parts = caption.components(separatedBy: invalid).joined(separator: " ")
        let joined = parts.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String((joined.isEmpty ? "Tshunhue" : joined).prefix(80))
    }
}

enum TransferError: LocalizedError {
    case cannotWritePasteboard

    var errorDescription: String? {
        switch self {
        case .cannotWritePasteboard: "The JPEG could not be copied to the pasteboard."
        }
    }
}
