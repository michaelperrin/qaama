import Foundation
import Observation
import OSLog

/// All the libraries Qaama knows about: the Apple Photos library plus the folders the user added,
/// the latter persisted in the catalog store.
@Observable
public final class LibraryCatalog {
    public let photos: PhotosLibrarySource
    /// Every photo of the Photos library and of the folders on one map. It reaches them through
    /// views of its own (`photosForMap`, `folderViews`), since it sets their query: filtering the
    /// map leaves the Photos library and the folders as their own entries show them.
    public let everywhere: CombinedLibrarySource
    public let photosAlbums = PhotosAlbumList()
    /// Creates and deletes the albums of the Photos library and files photos in them.
    public let photosAlbumEditor: PhotosAlbumEditor
    public private(set) var folders: [FolderLibrarySource] = []
    private var albumSources: [String: PhotosLibrarySource] = [:]
    public private(set) var isLoaded = false

    /// Renders full-size edits for sources that cache previews. Set once by the app.
    public var previewRenderer: PreviewRenderer? {
        didSet {
            folders.forEach { $0.previewRenderer = previewRenderer }
            folderViews.values.forEach { $0.previewRenderer = previewRenderer }
        }
    }

    private let store: CatalogStore
    /// One index for the Photos library, shared by the library source and every album source.
    private let photosIndex: PhotosIndex
    private let previewCache: PreviewCache
    private let photosForMap: PhotosLibrarySource
    /// A second view of each folder, which follows the catalog without scanning: the folder's own
    /// source does that.
    private var folderViews: [UUID: FolderLibrarySource] = [:]
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "LibraryCatalog")

    public init(store: CatalogStore, previewCache: PreviewCache = PreviewCache()) {
        self.store = store
        self.previewCache = previewCache
        photosIndex = PhotosIndex(store: PhotosIndexStore(catalog: store), library: PhotoKitIndexLibrary())
        photos = PhotosLibrarySource(index: photosIndex)
        photosForMap = PhotosLibrarySource(index: photosIndex)
        everywhere = CombinedLibrarySource(displayName: "Map", members: [photosForMap])
        photosAlbumEditor = PhotosAlbumEditor(library: PhotoKitAlbumLibrary(), list: photosAlbums)
        // Opening the map of everything scans the folders, as opening each of them does.
        everywhere.prepare = { [weak self] in
            for folder in self?.folders ?? [] {
                await folder.load()
            }
        }
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
            refreshEverywhere()
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
        refreshEverywhere()
        return source
    }

    public func removeFolder(_ folder: FolderLibrarySource) async throws {
        try await store.deleteFolder(id: folder.id)
        folders.removeAll { $0 === folder }
        folderViews[folder.id] = nil
        refreshEverywhere()
    }

    /// The folders first: they answer from memory when asked which source holds a photo.
    private func refreshEverywhere() {
        everywhere.setMembers(folders.compactMap { folderViews[$0.id] } + [photosForMap])
    }

    /// A source scoped to a Photos album, created on first use and kept for the session.
    public func photosSource(for album: PhotosAlbum) -> PhotosLibrarySource {
        if let existing = albumSources[album.id] {
            return existing
        }
        let source = PhotosLibrarySource(album: album, index: photosIndex)
        albumSources[album.id] = source
        return source
    }

    private func makeSource(folder: CatalogFolder, url: URL) -> FolderLibrarySource {
        let source = FolderLibrarySource(folder: folder, url: url, store: store, previewCache: previewCache)
        source.previewRenderer = previewRenderer
        let view = FolderLibrarySource(folder: folder, url: url, store: store, previewCache: previewCache, scans: false)
        view.previewRenderer = previewRenderer
        folderViews[folder.id] = view
        return source
    }
}
