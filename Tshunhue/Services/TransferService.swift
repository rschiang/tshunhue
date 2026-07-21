import CoreTransferable
import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct TransferFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            TransferFile(url: received.file)
        }
    }
}

struct FrameTransferItem: Transferable, Sendable {
    let frame: CatalogFrame
    let repository: ImageRepository
    let recentStore: RecentStore

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { value in
            let asset = try await value.repository.asset(for: value.frame.imageURL)
            let url = try TransferService.exportFile(for: value.frame, asset: asset)
            try await value.recentStore.record(value.frame.identity)
            return SentTransferredFile(url)
        } importing: { _ in
            throw CocoaError(.featureUnsupported)
        }
    }
}

@MainActor
enum TransferService {
    static func copy(_ asset: ImageAsset) throws {
        #if os(macOS)
        guard let image = NSImage(data: asset.data) else { throw ImageRepositoryError.cannotDecode }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setData(asset.data, forType: NSPasteboard.PasteboardType(asset.type.identifier))
        #elseif os(iOS)
        guard let image = UIImage(data: asset.data) else { throw ImageRepositoryError.cannotDecode }
        UIPasteboard.general.setItems([[
            asset.type.identifier: asset.data,
            UTType.image.identifier: image,
        ]])
        #endif
    }

    nonisolated static func exportFile(for frame: CatalogFrame, asset: ImageAsset) throws -> URL {
        let extensionName = asset.type.preferredFilenameExtension ?? "image"
        let base = sanitizedFilename(frame.frame.caption)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tshunhue Transfers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(base).appendingPathExtension(extensionName)
        try asset.data.write(to: url, options: .atomic)
        return url
    }

    nonisolated private static func sanitizedFilename(_ caption: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let parts = caption.components(separatedBy: invalid).filter { !$0.isEmpty }
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((joined.isEmpty ? "Tshunhue" : joined).prefix(80))
    }
}
