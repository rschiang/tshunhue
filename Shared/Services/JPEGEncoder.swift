//
//  JPEGEncoder.swift
//  Tshunhue
//
//  Normalizes outbound images into interoperable JPEG data.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes transfer images as oriented, opaque sRGB JPEGs.
enum JPEGEncoder {
    /// Preserves existing JPEG bytes or transcodes another static image format.
    static func data(for asset: ImageAsset) throws -> Data {
        if asset.type.conforms(to: .jpeg) {
            return asset.data
        }

        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(asset.width, asset.height),
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw JPEGEncodingError.cannotEncode
        }

        // JPEG has no alpha channel, so composite transparent sources onto white.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let flattened = context.makeImage() else { throw JPEGEncodingError.cannotEncode }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw JPEGEncodingError.cannotEncode
        }
        CGImageDestinationAddImage(destination, flattened, [
            kCGImageDestinationLossyCompressionQuality: 0.80,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw JPEGEncodingError.cannotEncode }
        return output as Data
    }
}

/// Failures produced while converting an image to JPEG.
enum JPEGEncodingError: LocalizedError {
    case cannotEncode

    var errorDescription: String? {
        "The image could not be converted to JPEG."
    }
}
