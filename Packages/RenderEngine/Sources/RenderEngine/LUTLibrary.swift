import CubeLUT
import Foundation
import OSLog
import Synchronization

/// The LUT files the user imported, copied into the app's Application Support folder so recipes
/// can name them whatever happens to the original files. A table's name is its file's, without
/// the extension: the folder is readable and files can be added or shared by hand.
///
/// The pipeline asks for tables by name on every render, from any thread: the last ones read stay
/// in memory, ready for Core Image.
public final nonisolated class LUTLibrary: Sendable {
    /// The library every render uses unless told otherwise.
    public static let shared = LUTLibrary()

    public static let fileExtension = "cube"

    /// A table ready for Core Image's color cube filter.
    public struct Table: Sendable {
        public let dimension: Int
        /// RGBA 32-bit floats, `dimension³` of them.
        public let data: Data
    }

    public enum LibraryError: Error, LocalizedError {
        /// The file isn't a table the app can use; `reason` ends the sentence.
        case unreadable(file: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(file, reason): "“\(file)” can't be used as a LUT: \(reason)"
            }
        }
    }

    public let directory: URL

    /// Larger tables are refitted to this size: 65 points per axis is the most LUT tools export for
    /// grading, and a cube of 129 would hold 34 MB of floats for no visible gain.
    static let maximumDimension = 65
    /// How much the tables kept in memory may weigh together: a dozen of the largest, a hundred of
    /// the usual 33-point ones.
    static let cacheLimit = 64 * 1024 * 1024

    /// Most recently used first. A nil table is a file that can't be read, remembered so it isn't
    /// parsed again on every render.
    private let cache = Mutex<[(name: String, table: Table?)]>([])
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "LUTLibrary")

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LUTs", isDirectory: true)
    }

    public init(directory: URL = LUTLibrary.defaultDirectory()) {
        self.directory = directory
    }

    /// The tables of the library, sorted as the Finder sorts their files.
    public func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == Self.fileExtension && !$0.lastPathComponent.hasPrefix(".") }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The table of that name, read once and kept; nil when the library has no readable file of
    /// that name. A missing file is looked for again each time, so importing it is enough to
    /// bring a look back.
    public func table(named name: String) -> Table? {
        if let cached = cache.withLock({ entries -> Table?? in
            guard let index = entries.firstIndex(where: { $0.name == name }) else { return nil }
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry.table
        }) {
            return cached
        }
        // Names come from recipes, which come from files: never a path out of the folder.
        guard !name.isEmpty, !name.contains("/"), let data = try? Data(contentsOf: url(for: name)) else { return nil }
        let start = ContinuousClock.now
        let table: Table?
        do {
            table = try Self.table(from: data)
            logger.notice("Read LUT \(name, privacy: .public) (\(table?.dimension ?? 0) points) in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))), privacy: .public)")
        } catch {
            table = nil
            logger.error("Unreadable LUT \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        cache.withLock { entries in
            entries.removeAll { $0.name == name }
            entries.insert((name, table), at: 0)
            var weight = 0
            let kept = entries.prefix { entry in
                weight += entry.table?.data.count ?? 0
                return weight <= Self.cacheLimit
            }.count
            // The one just asked for always stays, whatever it weighs.
            entries.removeSubrange(max(kept, 1)...)
        }
        return table
    }

    /// Copies a `.cube` file in, once it has been checked to be a table the app can read, and
    /// returns the name recipes refer to it by. The file's name is kept, with a counter when it is
    /// taken by another table; importing the same file twice gives the table already there.
    public func importFile(at url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        do {
            _ = try CubeLUT(cubeFile: data)
        } catch let error as CubeLUT.ParseError {
            throw LibraryError.unreadable(file: url.lastPathComponent, reason: error.localizedDescription)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A slash can't be in a name (the Finder shows a colon of the file system as one).
        let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: self.url(for: name).path) {
            if (try? Data(contentsOf: self.url(for: name))) == data {
                return name
            }
            name = "\(base) \(counter)"
            counter += 1
        }
        try data.write(to: self.url(for: name), options: .atomic)
        forget(name)
        logger.notice("Imported LUT \(name, privacy: .public)")
        return name
    }

    /// Removes a table from the library. Photos that name it render without it from then on.
    public func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: url(for: name))
        forget(name)
        logger.notice("Deleted LUT \(name, privacy: .public)")
    }

    private func forget(_ name: String) {
        cache.withLock { $0.removeAll { $0.name == name } }
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
    }

    static func table(from data: Data) throws -> Table {
        var lut = try CubeLUT(cubeFile: data)
        if lut.dimension > maximumDimension {
            lut = lut.resampled(to: maximumDimension)
        }
        return Table(dimension: lut.dimension, data: lut.rgbaData())
    }
}
