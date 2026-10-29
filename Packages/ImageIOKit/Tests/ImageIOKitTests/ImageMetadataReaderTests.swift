import CoreGraphics
import Foundation
import ImageIO
@testable import ImageIOKit
import Testing
import UniformTypeIdentifiers

struct ImageMetadataReaderTests {
    /// A JPEG with the EXIF and TIFF fields a camera would write, rotated 90° by orientation 6.
    private func writeSample() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-\(UUID().uuidString).jpg")
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM ", kCGImagePropertyTIFFModel: "X-T30"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:29 14:03:12",
                kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
                kCGImagePropertyExifLensModel: "XF35mmF2 R WR",
                kCGImagePropertyExifISOSpeedRatings: [800],
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifFocalLength: 35.0,
            ],
        ]
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func readsDimensionsOrientationAndExif() throws {
        let url = try writeSample()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try ImageMetadataReader.read(url)
        #expect(metadata.pixelWidth == 20 && metadata.pixelHeight == 40, "orientation 6 swaps the dimensions")
        #expect(metadata.orientation == 6)
        #expect(metadata.cameraMake == "FUJIFILM" && metadata.cameraModel == "X-T30")
        #expect(metadata.lens == "XF35mmF2 R WR")
        #expect(metadata.iso == 800)
        #expect(metadata.exposureTime == 0.004 && metadata.aperture == 2.8 && metadata.focalLength == 35)
        // 14:03:12 at +01:00 is 13:03:12 UTC.
        #expect(metadata.captureDate == ISO8601DateFormatter().date(from: "2026-10-29T13:03:12Z"))
    }

    @Test func parsesExifDatesWithoutOffsetInTheCurrentTimeZone() throws {
        let date = ImageMetadataReader.exifDate("2026:10:29 14:03:12", offset: nil)
        let components = try Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: #require(date))
        #expect(components.year == 2026 && components.month == 10 && components.day == 29 && components.hour == 14 && components.minute == 3)
        #expect(ImageMetadataReader.exifDate("garbage", offset: nil) == nil)
    }

    @Test func failsOnNonImages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-image-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ImageMetadataReader.ReadError.self) { try ImageMetadataReader.read(url) }
    }
}
