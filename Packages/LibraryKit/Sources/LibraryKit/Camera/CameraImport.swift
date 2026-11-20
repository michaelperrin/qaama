import Foundation
import Observation
import OSLog

/// How imported photos are filed in the folder they go to, by the day they were taken.
public nonisolated enum ImportLayout: String, CaseIterable, Sendable {
    /// A folder per day inside one per year: "2026/2026-11-19". The days of a year sort by name.
    case byDay
    /// Nested folders for the year, the month and the day: "2026/11/19".
    case yearMonthDay
    /// A folder per month inside one per year: "2026/11".
    case yearMonth
    /// A folder per year: "2026".
    case year
    /// A folder per day, all side by side: "2026-11-19".
    case day
    /// All in the folder itself.
    case flat

    /// The subdirectory a photo taken on `date` goes to, relative to the destination; nil for the
    /// destination itself. Photos without a date go to the destination itself too.
    public func subfolder(for date: Date?, calendar: Calendar = .current) -> String? {
        guard self != .flat, let date else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return switch self {
        case .byDay: String(format: "%04d/%04d-%02d-%02d", year, year, month, day)
        case .yearMonthDay: String(format: "%04d/%02d/%02d", year, month, day)
        case .yearMonth: String(format: "%04d/%02d", year, month)
        case .year: String(format: "%04d", year)
        case .day: String(format: "%04d-%02d-%02d", year, month, day)
        case .flat: nil
        }
    }

    /// Where photos taken on these dates will go, to show before importing: each subfolder with
    /// how many photos it gets, the most recent day first, the destination itself (photos without a
    /// date, or no subfolders at all) last.
    public func folders(for dates: some Sequence<Date?>, calendar: Calendar = .current) -> [ImportFolderPreview] {
        var counts: [String?: Int] = [:]
        for date in dates {
            counts[subfolder(for: date, calendar: calendar), default: 0] += 1
        }
        return counts.map { ImportFolderPreview(subfolder: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                switch (lhs.subfolder, rhs.subfolder) {
                case let (left?, right?): left > right
                case (nil, _): false
                case (_, nil): true
                }
            }
    }
}

/// One folder an import will put photos in.
public nonisolated struct ImportFolderPreview: Hashable, Sendable, Identifiable {
    /// Relative to the destination; nil for the destination itself.
    public let subfolder: String?
    public let count: Int

    public var id: String {
        subfolder ?? ""
    }
}

/// The files of one photo, copied from a device and checked, ready to become a photo of a library
/// that keeps its photos itself (Apple Photos).
public nonisolated struct ImportedPhoto: Sendable {
    public struct File: Sendable {
        /// Where the copy is: a temporary file, which whoever takes the photo may move away.
        public var url: URL
        /// The name the file has on the device.
        public var name: String
        public var isRAW: Bool
    }

    /// The photo's file, and the JPEG shot with it when it is a RAW that has one.
    public var files: [File]
}

/// Where imported photos go.
public nonisolated enum ImportDestination: Sendable {
    /// Files in a folder, filed by day or not.
    case folder(URL, layout: ImportLayout)
    /// A library that makes a photo of its own from the files and returns its identifier: Apple
    /// Photos, through `PhotosLibrarySource.importer(intoAlbum:)`.
    case library(@Sendable (ImportedPhoto) async throws -> String)
}

/// Why a photo couldn't be imported; the sentences can be shown as they are.
public nonisolated enum CameraImportError: Error, LocalizedError, Sendable {
    /// The device didn't hand the file over.
    case notDownloaded(String)
    /// The copy doesn't have the size the device announced: it isn't kept.
    case incomplete(String)
    /// The photo was imported, but its second copy couldn't be made, for this reason.
    case secondCopyFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .notDownloaded(name): "“\(name)” couldn't be read from the device."
        case let .incomplete(name): "The copy of “\(name)” was incomplete and wasn't kept."
        case let .secondCopyFailed(name, reason): "The second copy of “\(name)” couldn't be made: \(reason)"
        }
    }
}

/// One import of photos from a card or a camera into a folder: how far it is, and what it did.
///
/// Each file is copied by the device into a temporary folder of the app, checked against the size
/// the device announced, then moved to its place: a card pulled out halfway leaves no partial file
/// among the photos. A file already there under the same name and with the same size is left alone
/// and counted as already imported; one with the same name and another size keeps its place, and the
/// new one takes the next free name ("IMG_0001 2.JPG"). For a library that keeps its photos itself,
/// the checked copies are handed over photo by photo.
@Observable
public final class CameraImport: Identifiable {
    public nonisolated let id = UUID()
    public let deviceName: String
    public let destinationName: String
    /// How many photos were asked for; a RAW with its JPEG counts as one.
    public let total: Int
    /// The photos gone through so far, whatever came of each.
    public private(set) var done = 0
    /// The photos whose files were all there already.
    public private(set) var alreadyThere = 0
    /// The files that couldn't be copied, with the reason.
    public private(set) var failures: [String] = []
    /// The image files copied into the folder, for an import into one.
    public private(set) var imported: [URL] = []
    /// The photos made in the library, by identifier, for an import into one.
    public private(set) var createdPhotoIDs: [String] = []
    /// The files of the device that are at the destination now, copied by this import or found
    /// there: what the history remembers as imported.
    public private(set) var importedFiles: [ImportedFileSignature] = []
    /// The files the device may lose, as it names them: those that are at the destination and,
    /// when a second copy was asked for, in it too. What deleting the imported photos takes.
    public private(set) var importedFileIDs: [CameraFile.ID] = []
    public private(set) var isFinished = false
    public private(set) var isCancelled = false

    @ObservationIgnored private var task: Task<Void, Never>?

    init(deviceName: String, destinationName: String, total: Int) {
        self.deviceName = deviceName
        self.destinationName = destinationName
        self.total = total
    }

    /// The photos that got at least one file copied.
    public var importedCount: Int {
        done - alreadyThere - failedPhotos
    }

    @ObservationIgnored private var failedPhotos = 0

    public var progress: IndexingProgress {
        IndexingProgress(done: done, total: total)
    }

    /// Stops after the file being copied; what was copied stays.
    public func cancel() {
        guard !isFinished else { return }
        isCancelled = true
        task?.cancel()
    }

    /// Returns once the import is over, finished or cancelled.
    public func wait() async {
        await task?.value
    }

    func start(_ work: @escaping @MainActor (CameraImport) async -> Void) {
        task = Task {
            await work(self)
            isFinished = true
        }
    }

    /// What became of one photo: the files copied or the photo made, whether some files were there
    /// already, what failed.
    /// `files` are those at the destination now; `removable`, those of them that are safe to
    /// delete from the device (all of them, unless told).
    func record(copied: [URL] = [], photoID: String? = nil, skipped: Int = 0, errors: [String] = [], files: [CameraFile] = [],
                removable: [CameraFile.ID]? = nil)
    {
        done += 1
        importedFiles.append(contentsOf: files.map(ImportedFileSignature.init))
        importedFileIDs.append(contentsOf: removable ?? files.map(\.id))
        imported.append(contentsOf: copied)
        createdPhotoIDs.append(contentsOf: [photoID].compactMap(\.self))
        failures.append(contentsOf: errors)
        if photoID != nil {
            return
        }
        if !errors.isEmpty, copied.isEmpty {
            failedPhotos += 1
        } else if copied.isEmpty, skipped > 0 {
            alreadyThere += 1
        }
    }
}

/// Where a file of a device goes in a folder, and how it gets there.
nonisolated enum CameraImportFiles {
    /// What to do with a file about to be imported.
    enum Placement: Equatable {
        /// Copy it here.
        case copy(URL)
        /// A file of this name and size is there already.
        case alreadyThere
    }

    /// The place of a file named `name`, `byteSize` long, in `directory`: its own name when free,
    /// nothing to do when a file of that name and size is there, else the next free name.
    static func placement(name: String, byteSize: Int64, in directory: URL) -> Placement {
        let manager = FileManager.default
        let wanted = directory.appendingPathComponent(name)
        guard manager.fileExists(atPath: wanted.path(percentEncoded: false)) else { return .copy(wanted) }
        let existing = (try? manager.attributesOfItem(atPath: wanted.path(percentEncoded: false))[.size] as? Int64) ?? -1
        if byteSize > 0, existing == byteSize {
            return .alreadyThere
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) \(number)").appendingPathExtension(ext)
            if !manager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return .copy(candidate)
            }
            number += 1
        }
    }

    /// Checks a file the device just copied against the size it announced.
    static func check(_ downloaded: URL, expectedSize: Int64) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path(percentEncoded: false))[.size] as? Int64) ?? -1
        guard size > 0, expectedSize <= 0 || size == expectedSize else {
            throw CameraImportError.incomplete(downloaded.lastPathComponent)
        }
    }

    /// What placing a downloaded file did.
    struct Placed: Sendable {
        /// Where the file was moved to; nil when it was at the destination already.
        var installed: URL?
        /// Why the second copy couldn't be made, when one was asked for and wasn't.
        var secondCopyError: String?
    }

    /// Checks a file the device just copied, makes its second copy where one is wanted, then moves
    /// it to its place, or drops it when the destination had it already (it was then only read for
    /// the second copy). A second copy that fails doesn't stop the import: it is told.
    static func place(_ downloaded: URL, expectedSize: Int64, at destination: Placement, secondCopy: Placement?) throws -> Placed {
        let manager = FileManager.default
        var placed = Placed()
        do {
            try check(downloaded, expectedSize: expectedSize)
        } catch {
            try? manager.removeItem(at: downloaded)
            throw error
        }
        if case let .copy(copy)? = secondCopy {
            do {
                try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: downloaded, to: copy)
            } catch {
                placed.secondCopyError = CameraImportError.secondCopyFailed(downloaded.lastPathComponent, error.localizedDescription).localizedDescription
            }
        }
        if case let .copy(url) = destination {
            try install(downloaded, expectedSize: expectedSize, at: url)
            placed.installed = url
        } else {
            try? manager.removeItem(at: downloaded)
        }
        return placed
    }

    /// Where the second copy of a photo taken on `date` goes: always filed by day, whatever the
    /// destination does, since it is what one looks into when something went wrong.
    static func secondCopyDirectory(in folder: URL, for date: Date?) -> URL {
        ImportLayout.byDay.subfolder(for: date).map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
    }

    /// Checks a file the device just copied, and moves it to its place. The temporary copy is
    /// removed either way.
    static func install(_ downloaded: URL, expectedSize: Int64, at destination: URL) throws {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: downloaded) }
        try check(downloaded, expectedSize: expectedSize)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: downloaded, to: destination)
    }
}
