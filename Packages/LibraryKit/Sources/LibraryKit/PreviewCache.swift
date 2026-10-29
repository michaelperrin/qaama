import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Disk cache of rendered previews for edited photos, so thumbnails show the real edit scaled down
/// instead of re-applying the recipe on a small image.
///
/// One JPEG per (asset, modification date), long edge `maxPixelSize`, in the app's Caches folder.
/// Storing a new preview for an asset deletes its older ones. Thumbnails are cut from the preview
/// with ImageIO, which is fast and uses the embedded size hints.
public nonisolated struct PreviewCache: Sendable {
    public static let maxPixelSize = 2048

    private let directory: URL
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PreviewCache")

    /// Default location: `<Caches>/previews` in the app's container.
    public init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("previews", isDirectory: true)
    }

    // MARK: - Lookup

    public func previewURL(for asset: LibraryAsset) -> URL? {
        guard let date = asset.modificationDate else { return nil }
        let url = fileURL(assetID: asset.id, date: date)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Thumbnail fitting `pixelSize`, cut from the cached preview, or nil when there is no preview.
    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) -> CGImage? {
        guard let url = previewURL(for: asset),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(pixelSize.width, pixelSize.height)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Storage

    /// Downscales a full-size rendered JPEG to the preview size and stores it for `asset` at its
    /// current modification date. Older previews of the same asset are removed.
    public func store(renderedJPEG: Data, for asset: LibraryAsset) throws {
        guard let date = asset.modificationDate else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removePreviews(for: asset.id)

        guard let source = CGImageSourceCreateWithData(renderedJPEG as CFData, nil) else { throw CacheError.unreadableRender }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw CacheError.unreadableRender }

        let url = fileURL(assetID: asset.id, date: date)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CacheError.writeFailed(url)
        }
        CGImageDestinationAddImage(destination, preview, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CacheError.writeFailed(url) }
        logger.notice("Stored preview \(url.lastPathComponent, privacy: .public) (\(preview.width)x\(preview.height))")
    }

    /// Removes every preview of an asset, e.g. when its edit is reverted.
    public func removePreviews(for assetID: LibraryAsset.ID) {
        let prefix = Self.hash(assetID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Keys

    public enum CacheError: Error {
        case unreadableRender
        case writeFailed(URL)
    }

    /// `<sha256 of the asset id>-<modification date in seconds>.jpg`; seconds are stable across
    /// file systems and launches, where sub-second precision isn't.
    func fileURL(assetID: String, date: Date) -> URL {
        directory.appendingPathComponent("\(Self.hash(assetID))-\(Int(date.timeIntervalSince1970)).jpg")
    }

    private static func hash(_ assetID: String) -> String {
        SHA256.hash(data: Data(assetID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
