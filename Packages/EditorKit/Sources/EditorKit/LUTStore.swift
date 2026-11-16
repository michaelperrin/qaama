import Foundation
import Observation
import RenderEngine

/// The LUT library as the inspector shows it: the names to choose from, and what manages them.
/// The files and their reading belong to `LUTLibrary`, which the renders use.
@Observable
public final class LUTStore {
    public private(set) var names: [String] = []

    public let library: LUTLibrary

    /// The folder the tables are kept in, to show it in the Finder.
    public var directory: URL {
        library.directory
    }

    public init(library: LUTLibrary = .shared) {
        self.library = library
        reload()
    }

    /// Lists the folder again: tables may have been added by hand or from another window.
    public func reload() {
        let listed = library.names()
        if listed != names {
            names = listed
        }
    }

    /// What an import did: the tables now in the library, in the order of the files, and one
    /// message per file that couldn't be used, ready to show.
    public struct ImportReport: Sendable, Equatable {
        public var imported: [String] = []
        public var failures: [String] = []
    }

    /// Copies `.cube` files into the library. Each is read whole to be checked, off the main actor:
    /// a pack of looks is hundreds of files.
    public func importFiles(at urls: [URL]) async -> ImportReport {
        let library = library
        let report = await Task.detached(priority: .userInitiated) {
            var report = ImportReport()
            for url in urls {
                do {
                    try report.imported.append(library.importFile(at: url))
                } catch {
                    report.failures.append(error.localizedDescription)
                }
            }
            return report
        }.value
        reload()
        return report
    }

    public func delete(_ name: String) throws {
        try library.delete(name)
        reload()
    }
}
