import Foundation
import Observation
import OSLog

/// All the libraries Qaama knows about: the Apple Photos library plus the folders the user added,
/// the latter persisted in the catalog store.
@Observable
public final class LibraryCatalog {
    public let photos = PhotosLibrarySource()
    public let photosAlbums = PhotosAlbumList()
    public private(set) var folders: [FolderLibrarySource] = []
    private var albumSources: [String: PhotosLibrarySource] = [:]
    public private(set) var isLoaded = false

    /// Renders full-size edits for sources that cache previews. Set once by the app.
    public var previewRenderer: PreviewRenderer? {
        didSet { folders.forEach { $0.previewRenderer = previewRenderer } }
    }

    private let store: CatalogStore
    private let previewCache: PreviewCache
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "LibraryCatalog")

    public init(store: CatalogStore, previewCache: PreviewCache = PreviewCache()) {
        self.store = store
        self.previewCache = previewCache
    }

    /// Restores the folders saved in the catalog. Unresolvable bookmarks are dropped.
    public func load() async {
        guard !isLoaded else { return }
        do {
            var restored: [FolderLibrarySource] = []
            for var folder in try await store.folders() {
                guard let (url, isStale) = try? SecurityBookmark.resolve(folder.bookmark) else {
                    logger.notice("Dropping folder \(folder.displayName, privacy: .public): its bookmark no longer resolves")
                    try await store.deleteFolder(id: folder.id)
                    continue
                }
                let source = makeSource(folder: folder, url: url)
                if isStale, let fresh = try? SecurityBookmark.make(for: url) {
                    folder.bookmark = fresh
                    try await store.save(folder)
                }
                restored.append(source)
            }
            folders = restored
        } catch {
            logger.error("Couldn't restore folders: \(error.localizedDescription, privacy: .public)")
        }
        isLoaded = true
    }

    /// Adds a folder picked by the user and remembers it across launches.
    /// Returns the existing source when the folder is already in the catalog.
    @discardableResult
    public func addFolder(_ url: URL) async throws -> FolderLibrarySource {
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
        let folder = try CatalogFolder(bookmark: SecurityBookmark.make(for: url), displayName: url.lastPathComponent)
        try await store.save(folder)
        let source = makeSource(folder: folder, url: url)
        folders.append(source)
        return source
    }

    public func removeFolder(_ folder: FolderLibrarySource) async throws {
        try await store.deleteFolder(id: folder.id)
        folders.removeAll { $0 === folder }
    }

    /// A source scoped to a Photos album, created on first use and kept for the session.
    public func photosSource(for album: PhotosAlbum) -> PhotosLibrarySource {
        if let existing = albumSources[album.id] {
            return existing
        }
        let source = PhotosLibrarySource(album: album)
        albumSources[album.id] = source
        return source
    }

    private func makeSource(folder: CatalogFolder, url: URL) -> FolderLibrarySource {
        let source = FolderLibrarySource(folder: folder, url: url, store: store, previewCache: previewCache)
        source.previewRenderer = previewRenderer
        return source
    }
}
