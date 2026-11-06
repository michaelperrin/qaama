import Foundation
import ImageIO

/// Rewrites values in the ImageIO properties of a file about to be written: the corrections the user
/// made to what the original says. Pure dictionary work, the inverse of `ImageMetadataReader`.
public nonisolated enum ImageMetadataWriter {
    /// Replaces the capture date. The time is spelled in the zone of the offset the properties already
    /// carry, so a photo keeps its local time; without one it is spelled in `fallback` and the offset
    /// is written too, which leaves no doubt about the instant. Sub-second tags go: they belonged to
    /// the date replaced.
    public static func settingCaptureDate(_ date: Date, in properties: [CFString: Any], fallback: TimeZone = .current) -> [CFString: Any] {
        var properties = properties
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let zone = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String).flatMap(ExifDate.timeZone(fromOffset:)) ?? fallback
        let text = ExifDate.string(from: date, in: zone)
        let offset = ExifDate.offsetString(of: zone, at: date)
        exif[kCGImagePropertyExifDateTimeOriginal] = text
        exif[kCGImagePropertyExifDateTimeDigitized] = text
        exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
        exif[kCGImagePropertyExifOffsetTimeDigitized] = offset
        exif[kCGImagePropertyExifSubsecTimeOriginal] = nil
        exif[kCGImagePropertyExifSubsecTimeDigitized] = nil
        properties[kCGImagePropertyExifDictionary] = exif

        // IPTC keeps its own copy of the capture date; left alone, it would contradict the EXIF one.
        if var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           iptc[kCGImagePropertyIPTCDateCreated] != nil || iptc[kCGImagePropertyIPTCTimeCreated] != nil
        {
            let parts = text.split(separator: " ")
            iptc[kCGImagePropertyIPTCDateCreated] = parts[0].replacingOccurrences(of: ":", with: "")
            iptc[kCGImagePropertyIPTCTimeCreated] = parts[1].replacingOccurrences(of: ":", with: "") + offset.replacingOccurrences(of: ":", with: "")
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }
        return properties
    }
}
