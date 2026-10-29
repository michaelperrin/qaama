import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lists the image files below a folder, recursively.
///
/// Blocking file-system and image-header work: call it off the main actor.
public nonisolated enum FolderScanner {
    private static let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .creationDateKey]

    /// Returns one asset per image file found below `folder`, newest first.
    /// The asset identifier is the file path, so `URL(filePath: asset.id)` gets the file back.
    public static func scan(_ folder: URL) throws -> [LibraryAsset] {
        var isDirectory: ObjCBool = false
        // The enumerator stays silent on a missing folder, so check it up front.
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: folder,
                  includingPropertiesForKeys: Array(resourceKeys),
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else {
            throw LibrarySourceError.folderUnreadable(folder)
        }

        let exifDateFormatter = DateFormatter()
        exifDateFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exifDateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var assets: [LibraryAsset] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  let type = values.contentType, type.conforms(to: .image) else { continue }
            assets.append(makeAsset(for: url, fileCreationDate: values.creationDate, exifDateFormatter: exifDateFormatter))
        }
        assets.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        return assets
    }

    /// Reads the image header only (dimensions, orientation, capture date); no pixels are decoded.
    private static func makeAsset(for url: URL, fileCreationDate: Date?, exifDateFormatter: DateFormatter) -> LibraryAsset {
        var width = 0
        var height = 0
        var captureDate: Date?

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any]
        {
            width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            // Orientations 5 to 8 are rotated by 90°: report the dimensions as displayed.
            if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
                swap(&width, &height)
            }
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            {
                captureDate = exifDateFormatter.date(from: taken)
            }
        }

        return LibraryAsset(
            id: url.standardizedFileURL.path(percentEncoded: false),
            pixelWidth: width,
            pixelHeight: height,
            creationDate: captureDate ?? fileCreationDate,
            isFavorite: false
        )
    }
}
