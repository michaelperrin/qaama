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

    static func metadata(from properties: [CFString: Any]) -> ImageMetadata {
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

        return ImageMetadata(
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation,
            captureDate: (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap {
                exifDate($0, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            },
            cameraMake: (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed,
            cameraModel: (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed,
            lens: ((exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String))?.trimmed,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            exposureTime: exif[kCGImagePropertyExifExposureTime] as? Double,
            aperture: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double
        )
    }

    /// EXIF dates are local wall-clock times ("2026:10:29 14:03:12"); the optional offset ("+01:00")
    /// pins them to an instant, otherwise the current time zone is assumed.
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset, let zone = timeZone(fromOffset: offset) {
            formatter.timeZone = zone
        }
        return formatter.date(from: text)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let parts = offset.dropFirst().split(separator: ":")
        guard offset.count == 6, parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let sign = offset.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}

private nonisolated extension String {
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
