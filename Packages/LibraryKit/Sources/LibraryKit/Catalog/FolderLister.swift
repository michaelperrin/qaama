import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// One image file found by `FolderLister`, with the system attributes that identify it.
public nonisolated struct ListedFile: Hashable, Sendable {
    public let url: URL
    /// Path from the folder root, e.g. `Trip/DSCF0001.RAF`.
    public let relativePath: String
    public let fileType: UTType
    public let fileSize: Int64
    public let contentModified: Date
    /// Serialized `fileResourceIdentifier`: survives renames and moves within the volume.
    public let fileIdentifier: Data?
    /// Modification date of the `.qaama` sidecar next to the file, when there is one.
    public let sidecarModified: Date?

    public var isRAW: Bool {
        fileType.conforms(to: .rawImage)
    }
}

/// Result of `FolderLister.list`: the images, plus sidecars whose image is gone or was renamed.
public nonisolated struct FolderListing: Sendable {
    public var files: [ListedFile]
    /// Relative paths of `.qaama` files with no image next to them.
    public var orphanSidecars: [String]
}

/// Phase A of a scan: lists the image files below a folder with their system attributes only.
/// No image header is read here; that is `ImageMetadataReader`'s job, in the background.
///
/// Blocking file-system work: call it off the main actor.
public nonisolated enum FolderLister {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey,
    ]

    public static func list(_ folder: URL) throws -> FolderListing {
        var isDirectory: ObjCBool = false
        let root = folder.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: root, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else {
            throw LibrarySourceError.folderUnreadable(folder)
        }

        let rootPath = root.path(percentEncoded: false)
        var images: [(ListedFile, sidecarKey: String)] = []
        var sidecarDates: [String: Date] = [:]

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: resourceKeys), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(rootPath) else { continue }
            let relativePath = String(path.dropFirst(rootPath.count)).trimmingPrefix("/")

            if url.pathExtension == EditingFormat.sidecarExtension {
                sidecarDates[String(relativePath)] = values.contentModificationDate
                continue
            }
            guard let type = values.contentType, type.conforms(to: .image) else { continue }
            let file = ListedFile(
                url: url,
                relativePath: String(relativePath),
                fileType: type,
                fileSize: Int64(values.fileSize ?? 0),
                contentModified: values.contentModificationDate ?? .distantPast,
                fileIdentifier: values.fileResourceIdentifier.flatMap(serialize),
                sidecarModified: nil
            )
            images.append((file, sidecarKey: "\(relativePath).\(EditingFormat.sidecarExtension)"))
        }

        var unclaimed = Set(sidecarDates.keys)
        let files = images.map { file, sidecarKey in
            guard let date = sidecarDates[sidecarKey] else { return file }
            unclaimed.remove(sidecarKey)
            return ListedFile(url: file.url, relativePath: file.relativePath, fileType: file.fileType, fileSize: file.fileSize,
                              contentModified: file.contentModified, fileIdentifier: file.fileIdentifier, sidecarModified: date)
        }
        return FolderListing(files: files, orphanSidecars: unclaimed.sorted())
    }

    private static func serialize(_ identifier: any NSCopying & NSCoding & NSSecureCoding) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true)
    }
}

/// Size, date and partial content hash of a file: recognizes a copy on another volume.
public nonisolated enum Fingerprint {
    static let sampleSize = 64 * 1024

    public static func compute(for url: URL, fileSize: Int64, contentModified: Date) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sample = try handle.read(upToCount: sampleSize) ?? Data()
        var hasher = SHA256()
        hasher.update(data: sample)
        hasher.update(data: Data("\(fileSize)-\(Int(contentModified.timeIntervalSince1970))".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
