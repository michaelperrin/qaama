import CoreGraphics
import Foundation
import ImageIO
@testable import LibraryKit
import Testing
import UniformTypeIdentifiers

struct PreviewCacheTests {
    private func makeCache() -> (PreviewCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewCacheTests-\(UUID().uuidString)")
        return (PreviewCache(directory: directory), directory)
    }

    /// A solid JPEG of the given size, as the editor would render it.
    private func jpeg(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func asset(date: Date) -> LibraryAsset {
        LibraryAsset(id: "/photos/a.jpg", pixelWidth: 4000, pixelHeight: 2000, creationDate: nil, isFavorite: false,
                     modificationDate: date, hasEdit: true)
    }

    @Test func storesADownscaledPreviewAndServesThumbnails() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let edited = asset(date: Date(timeIntervalSince1970: 1000))

        #expect(cache.previewURL(for: edited) == nil)
        try cache.store(renderedJPEG: jpeg(width: 4000, height: 2000), for: edited)

        let url = try #require(cache.previewURL(for: edited))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == PreviewCache.maxPixelSize)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == PreviewCache.maxPixelSize / 2)

        let thumbnail = try #require(cache.thumbnail(for: edited, pixelSize: CGSize(width: 320, height: 320)))
        #expect(thumbnail.width == 320 && thumbnail.height == 160)
    }

    @Test func newEditReplacesOlderPreviews() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = asset(date: Date(timeIntervalSince1970: 1000))
        let second = asset(date: Date(timeIntervalSince1970: 2000))

        try cache.store(renderedJPEG: jpeg(width: 40, height: 20), for: first)
        try cache.store(renderedJPEG: jpeg(width: 40, height: 20), for: second)

        #expect(cache.previewURL(for: first) == nil)
        #expect(cache.previewURL(for: second) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)

        cache.removePreviews(for: second.id)
        #expect(cache.previewURL(for: second) == nil)
    }

    @Test func ignoresAssetsWithoutModificationDate() {
        let (cache, _) = makeCache()
        let undated = LibraryAsset(id: "/photos/b.jpg", pixelWidth: 1, pixelHeight: 1, creationDate: nil, isFavorite: false)
        #expect(cache.previewURL(for: undated) == nil)
        #expect(cache.thumbnail(for: undated, pixelSize: CGSize(width: 10, height: 10)) == nil)
    }
}
