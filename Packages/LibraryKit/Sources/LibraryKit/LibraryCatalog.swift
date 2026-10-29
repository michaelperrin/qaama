import Foundation
import Observation

/// All the libraries Qaama knows about: the Apple Photos library plus the folders the user added.
@Observable
public final class LibraryCatalog {
    public let photos = PhotosLibrarySource()
    public private(set) var folders: [FolderLibrarySource] = []

    private let bookmarks = FolderBookmarkStore()

    public init() {
        folders = bookmarks.restoreFolders().map { FolderLibrarySource(folderURL: $0) }
    }

    /// Adds a folder picked by the user and remembers it across launches.
    /// Returns the existing source when the folder is already in the catalog.
    @discardableResult
    public func addFolder(_ url: URL) throws -> FolderLibrarySource {
        let standardized = url.standardizedFileURL
        if let existing = folders.first(where: { $0.folderURL.standardizedFileURL == standardized }) {
            return existing
        }
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try bookmarks.add(url)
        let source = FolderLibrarySource(folderURL: url)
        folders.append(source)
        return source
    }

    public func removeFolder(_ folder: FolderLibrarySource) {
        bookmarks.remove(folder.folderURL)
        folders.removeAll { $0 === folder }
    }
}
