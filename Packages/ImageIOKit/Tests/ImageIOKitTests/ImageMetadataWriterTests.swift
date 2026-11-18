import CoreGraphics
import Foundation
import ImageIO
@testable import ImageIOKit
import Testing

struct ImageMetadataWriterTests {
    private let paris = TimeZone(identifier: "Europe/Paris")!
    /// 29 October 2026, 13:03:12 UTC: 14:03:12 in Paris, in winter time.
    private let instant = ISO8601DateFormatter().date(from: "2026-10-29T13:03:12Z")!

    @Test func offsetsAreSpelledAndReadBack() throws {
        #expect(ExifDate.offsetString(of: paris, at: instant) == "+01:00")
        // Summer time: the same zone is two hours ahead.
        #expect(ExifDate.offsetString(of: paris, at: instant.addingTimeInterval(-100 * 86400)) == "+02:00")
        #expect(try ExifDate.offsetString(of: #require(TimeZone(secondsFromGMT: -12600)), at: instant) == "-03:30")
        #expect(ExifDate.timeZone(fromOffset: "-03:30")?.secondsFromGMT() == -12600)
        #expect(ExifDate.timeZone(fromOffset: "0100") == nil && ExifDate.timeZone(fromOffset: "Z") == nil)
    }

    @Test func aPhotoWithAnOffsetKeepsItsLocalTime() {
        // Shot in Tokyo (+09:00): the corrected date is still spelled in Tokyo time, whatever the Mac's zone.
        let original: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:29 20:00:00",
            kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
            kCGImagePropertyExifSubsecTimeOriginal: "42",
            kCGImagePropertyExifLensModel: "XF35mmF2 R WR",
        ] as [CFString: Any]]

        let corrected = ImageMetadataWriter.settingCaptureDate(instant, in: original, fallback: paris)
        let exif = corrected[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:29 22:03:12")
        #expect(exif[kCGImagePropertyExifDateTimeDigitized] as? String == "2026:10:29 22:03:12")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+09:00")
        #expect(exif[kCGImagePropertyExifSubsecTimeOriginal] == nil)
        #expect(exif[kCGImagePropertyExifLensModel] as? String == "XF35mmF2 R WR", "the rest of the header is untouched")
        #expect(ImageMetadataReader.metadata(from: corrected).captureDate == instant)
    }

    @Test func aPhotoWithoutAnOffsetGetsTheFallbackZoneAndSaysSo() {
        let corrected = ImageMetadataWriter.settingCaptureDate(instant, in: [:], fallback: paris)
        let exif = corrected[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:29 14:03:12")
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+01:00")
        #expect(ImageMetadataReader.metadata(from: corrected).captureDate == instant)
    }

    @Test func theIPTCCopyOfTheDateFollows() {
        let original: [CFString: Any] = [kCGImagePropertyIPTCDictionary: [
            kCGImagePropertyIPTCDateCreated: "20200101", kCGImagePropertyIPTCTimeCreated: "000000+0000",
            kCGImagePropertyIPTCCity: "Paris",
        ] as [CFString: Any]]
        let iptc = ImageMetadataWriter.settingCaptureDate(instant, in: original, fallback: paris)[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        #expect(iptc[kCGImagePropertyIPTCDateCreated] as? String == "20261029")
        #expect(iptc[kCGImagePropertyIPTCTimeCreated] as? String == "140312+0100")
        #expect(iptc[kCGImagePropertyIPTCCity] as? String == "Paris")
        // No IPTC date to begin with: none is invented.
        #expect(ImageMetadataWriter.settingCaptureDate(instant, in: [:], fallback: paris)[kCGImagePropertyIPTCDictionary] == nil)
    }

    @Test func aLocationCorrectionReplacesOrRemovesTheGPSBlock() throws {
        let original: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 35.0,
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "XF35mmF2 R WR"] as [CFString: Any],
        ]
        // Rio de Janeiro: south and west.
        let rio = GeoCoordinate(latitude: -22.9519, longitude: -43.2105)
        let moved = ImageMetadataWriter.applying(.place(rio), to: original)
        let gps = try #require(moved[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(ImageMetadataReader.location(from: gps) == rio)
        #expect(gps[kCGImagePropertyGPSAltitude] == nil, "the altitude was the other place's")
        #expect(moved[kCGImagePropertyExifDictionary] != nil, "the rest stays")

        let removed = ImageMetadataWriter.applying(.removed, to: original)
        #expect(removed[kCGImagePropertyGPSDictionary] == nil && removed[kCGImagePropertyExifDictionary] != nil)
    }

    @Test func aCorrectionIsOnlyWhatDiffersFromTheFile() {
        let paris = GeoCoordinate(latitude: 48.8584, longitude: 2.2945), nearby = GeoCoordinate(latitude: 48.858_400_1, longitude: 2.2945)
        let lyon = GeoCoordinate(latitude: 45.764, longitude: 4.8357)
        #expect(LocationCorrection.between(file: nil, location: nil) == nil)
        #expect(LocationCorrection.between(file: paris, location: nearby) == nil)
        #expect(LocationCorrection.between(file: paris, location: lyon) == .place(lyon))
        #expect(LocationCorrection.between(file: nil, location: lyon) == .place(lyon))
        #expect(LocationCorrection.between(file: paris, location: nil) == .removed)
        #expect(LocationCorrection.removed.location == nil && LocationCorrection.place(lyon).location == lyon)
    }
}
