import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing

/// Loads images from files on disk: Quick Look for thumbnails, ImageIO for full-size decoding.
nonisolated enum FileImageLoader {
    /// Thumbnail fitting `pixelSize`, from the embedded preview when the file has one (fast for RAW files).
    static func thumbnail(at url: URL, pixelSize: CGSize) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: pixelSize, scale: 1, representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { @Sendable representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }

    /// Full-size image decoded with ImageIO (Apple's RAW engine for RAW files), EXIF orientation applied.
    static func fullSizeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Asking for a "thumbnail" at full size is the ImageIO way to get an oriented, fully decoded image.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
