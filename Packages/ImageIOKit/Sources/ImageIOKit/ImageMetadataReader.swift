import Foundation
import ImageIO

/// Reads image headers with ImageIO: dimensions, orientation and the EXIF fields the library sorts
/// and filters on. Works on every format ImageIO decodes, RAW included (a few milliseconds per file).
///
/// Blocking I/O: call it off the main actor.
public nonisolated enum ImageMetadataReader {
    public enum ReadError: Error, LocalizedError {
        case unreadable(URL)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(url): "The header of “\(url.lastPathComponent)” can't be read."
            }
        }
    }

    public static func read(_ url: URL) throws -> ImageMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else {
            throw ReadError.unreadable(url)
        }
        return metadata(from: properties)
    }

    /// The same reading from ImageIO properties already in hand.
    public static func metadata(from properties: [CFString: Any]) -> ImageMetadata {
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5 to 8 are rotated by 90°: report the dimensions as displayed.
        if orientation >= 5 {
            swap(&width, &height)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        return ImageMetadata(
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation,
            captureDate: (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap {
                ExifDate.date(from: $0, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            },
            cameraMake: (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed,
            cameraModel: (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed,
            lens: ((exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String))?.trimmed,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            aperture: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            location: location(from: gps)
        )
    }

    /// GPS tags hold unsigned degrees and a hemisphere letter ("S", "W" for the negative sides). A
    /// position out of range, or exactly 0° / 0° (what some cameras write without a fix), is no position.
    static func location(from gps: [CFString: Any]) -> GeoCoordinate? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude] as? Double, let longitude = gps[kCGImagePropertyGPSLongitude] as? Double,
              (0 ... 90).contains(latitude), (0 ... 180).contains(longitude), latitude != 0 || longitude != 0
        else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return GeoCoordinate(latitude: south ? -latitude : latitude, longitude: west ? -longitude : longitude)
    }
}

private nonisolated extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
