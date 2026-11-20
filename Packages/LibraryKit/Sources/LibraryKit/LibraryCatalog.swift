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
    /// The filters the user saved, each with the library it filters (`library(for:)`).
    public let filterPresets: FilterPresetStore
    /// The cards and cameras plugged in, to import photos from.
    public let cameras: CameraDevices
    /// The import settings saved under a name.
    public let importPresets: ImportPresetStore

    /// Renders full-size edits for sources that cache previews. Set once by the app.
    public var previewRenderer: PreviewRenderer? {
        didSet {
            folders.forEach { $0.previewRenderer = previewRenderer }
            folderViews.values.forEach { $0.previewRenderer = previewRenderer }
            for case let .folder(view, _, _) in presetLibraries.values {
                view.previewRenderer = previewRenderer
            }
        }
    }

    /// What a filter preset shows: a view of its library that is the preset's own, so its filters
    /// leave the library as its own entry of the sidebar shows it.
    public enum PresetLibrary {
        case photos(PhotosLibrarySource)
        /// The view, the folder's own source (which scans it and watches it), and the subdirectory
        /// the preset is about, if any.
        case folder(FolderLibrarySource, scannedBy: FolderLibrarySource, path: String?)

        public var source: any LibrarySource {
            switch self {
            case let .photos(source): source
            case let .folder(view, _, _): view
            }
        }
    }

    private let store: CatalogStore
    private let photosIndexStore: PhotosIndexStore
    /// One index for the Photos library, shared by the library source and every album source.
    private let photosIndex: PhotosIndex
    private let previewCache: PreviewCache
    private let photosForMap: PhotosLibrarySource
    /// A second view of each folder, which follows the catalog without scanning: the folder's own
    /// source does that.
    private var folderViews: [UUID: FolderLibrarySource] = [:]
    /// The views made for the presets shown so far, kept for the session. Asked from views' bodies,
    /// hence not observed.
    @ObservationIgnored private var presetLibraries: [FilterPreset.ID: PresetLibrary] = [:]
    /// The views made for the imports shown so far, kept for the session.
    @ObservationIgnored private var importLibraries: [ImportRecord.ID: PresetLibrary] = [:]
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "LibraryCatalog")

    /// `filterPresets` are kept in memory unless a store with a file is handed in (the app's), and
    /// no card or camera is ever listed unless `cameras` come with a browser (the app's too).
    public init(store: CatalogStore, previewCache: PreviewCache = PreviewCache(), filterPresets: FilterPresetStore = FilterPresetStore(),
                cameras: CameraDevices = CameraDevices(), importPresets: ImportPresetStore = ImportPresetStore())
    {
        self.importPresets = importPresets
        self.store = store
        self.previewCache = previewCache
        self.filterPresets = filterPresets
        self.cameras = cameras
        photosIndexStore = PhotosIndexStore(catalog: store)
        photosIndex = PhotosIndex(store: photosIndexStore, library: PhotoKitIndexLibrary())
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
        cameras.start()
        await cameras.history?.load()
        await filterPresets.load()
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

    /// The view of its library a preset shows, made on first use with the preset's filters, so its
    /// first listing is the filtered one, and kept for the session. Nil when the library is gone
    /// (an album deleted, a folder removed) or, for an album, not listed yet (`photosAlbums.isLoaded`).
    public func library(for preset: FilterPreset) -> PresetLibrary? {
        presetLibraries = presetLibraries.filter { filterPresets.preset(id: $0.key) != nil }
        let known = presetLibraries[preset.id]
        let library: PresetLibrary
        switch preset.library {
        case .photos:
            library = known ?? .photos(PhotosLibrarySource(index: photosIndex))
        case let .photosAlbum(id):
            guard let album = photosAlbums.album(id: id) else { return nil }
            library = known ?? .photos(PhotosLibrarySource(album: album, index: photosIndex))
        case let .folder(id, path):
            // A folder removed and added again is another source: its view is made again.
            guard let folder = folders.first(where: { $0.id == id }) else { return nil }
            if case let .folder(view, scannedBy, _) = known, scannedBy === folder {
                library = .folder(view, scannedBy: folder, path: path)
            } else {
                library = .folder(folder.makeView(), scannedBy: folder, path: path)
            }
        }
        if known == nil {
            library.source.query.filters = preset.settings.filters()
        }
        presetLibraries[preset.id] = library
        return library
    }

    // MARK: - Keywords

    /// The keywords in use in the folders and in the Photos library, sorted as the Finder sorts
    /// names: what a keyword field offers to pick from. A flat list for now.
    public func knownKeywords() async -> [String] {
        let fromFolders = await (try? store.allKeywords()) ?? []
        let fromPhotos = await (try? photosIndexStore.allKeywords()) ?? []
        return fromFolders.union(fromPhotos).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Imports

    /// What an import shows through: a view of its own of the library the photos went to, cut
    /// down to those photos, so the library's own entry of the sidebar stays as it is. Nil when
    /// the folder it went to was removed. Call `refreshImport(_:)` for the photos to be found.
    public func library(forImport record: ImportRecord) -> PresetLibrary? {
        if let known = importLibraries[record.id] {
            return known
        }
        let library: PresetLibrary
        switch record.destination {
        case .photos:
            let source = PhotosLibrarySource(index: photosIndex)
            source.query.fixedAssetIDs = Set(record.photoIDs)
            library = .photos(source)
        case let .folder(id):
            guard let folder = folders.first(where: { $0.id == id }) else { return nil }
            let view = folder.makeView()
            view.previewRenderer = previewRenderer
            // Nothing until the files are found in the catalog: never the whole folder.
            view.query.fixedAssetIDs = []
            library = .folder(view, scannedBy: folder, path: nil)
        }
        importLibraries[record.id] = library
        return library
    }

    /// Finds the photos of an import in the catalog, for a folder: the files an import copied
    /// are only known there once the folder has been listed again, so this is called when the view
    /// shows and each time the folder's listing changes.
    public func refreshImport(_ record: ImportRecord) async {
        guard case let .folder(id) = record.destination, case let .folder(view, _, _) = library(forImport: record) else { return }
        let ids = await (try? store.itemIDs(inFolder: id, relativePaths: record.relativePaths)) ?? []
        let found = Set(ids.map(\.uuidString))
        if view.query.fixedAssetIDs != found {
            view.query.fixedAssetIDs = found
        }
    }

    private func makeSource(folder: CatalogFolder, url: URL) -> FolderLibrarySource {
        let source = FolderLibrarySource(folder: folder, url: url, store: store, previewCache: previewCache)
        source.previewRenderer = previewRenderer
        folderViews[folder.id] = source.makeView()
        return source
    }
}
