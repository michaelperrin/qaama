import CoreGraphics
import Foundation
import ImageIOKit
import Observation
import OSLog

/// "Folder on disk" source, backed by the catalog: the grid shows catalog items and follows their
/// changes, while the indexers refresh the catalog from the folder in the background.
///
/// Holds the security-scoped access to the folder for as long as it lives. Decisions (rating, flag,
/// keywords, recipe) are written to the sidecar first, then mirrored into the catalog.
@Observable
public final class FolderLibrarySource: LibrarySource, Identifiable {
    public let id: UUID
    public let folderURL: URL
    public let displayName: String
    public private(set) var assets: AssetCollection = .empty
    /// Duration of the listing phase of the last scan.
    public private(set) var lastLoadDuration: Duration?
    /// True once the catalog has delivered the items (even if a scan is still running).
    public private(set) var isLoaded = false
    public private(set) var isScanning = false
    /// Directory tree of the folder, refreshed after each scan.
    public private(set) var subfolders: [FolderNode] = []
    /// Message to show when the folder could not be listed.
    public private(set) var loadError: String?

    public var capabilities: Set<LibraryCapability> {
        [.rating, .flag, .keywords]
    }

    public var queryCapabilities: Set<QueryCapability> {
        [.sortByRating, .sortByFileName, .rating, .flag, .edited, .raw, .search]
    }

    /// Sorting and filtering, answered by the catalog; changing it restarts the observation.
    public var query = LibraryQuery.default {
        didSet {
            guard query != oldValue, observation != nil else { return }
            startObservation()
        }
    }

    /// Rebuilds the preview of an edited photo when the cache has none. Set by the catalog.
    public var previewRenderer: PreviewRenderer?

    private let folder: CatalogFolder
    private let store: CatalogStore
    private let previewCache: PreviewCache
    private let hasSecurityScope: Bool
    private var itemsByID: [UUID: CatalogItem] = [:]
    private var observation: Task<Void, Never>?
    private var scan: Task<Void, Never>?
    private var watcher: FolderWatcher?
    /// A scan requested while one was running: run again when it ends, the folder changed meanwhile.
    private var rescanRequested = false
    /// Items recently shown on screen, read first by the metadata phase.
    private var prioritized: Set<UUID> = []
    private var previewsInProgress: Set<LibraryAsset.ID> = []
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FolderLibrarySource")

    public init(folder: CatalogFolder, url: URL, store: CatalogStore, previewCache: PreviewCache = PreviewCache()) {
        id = folder.id
        self.folder = folder
        folderURL = url
        displayName = folder.displayName
        self.store = store
        self.previewCache = previewCache
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    isolated deinit {
        watcher?.stop()
        observation?.cancel()
        scan?.cancel()
        if hasSecurityScope {
            folderURL.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Loading

    /// Starts following the catalog, then scans the folder. Returns once the catalog delivered its items.
    public func load() async {
        guard observation == nil else { return }
        startObservation()
        while !isLoaded, let observation, !observation.isCancelled {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        rescan()
        // From now on the Finder drives rescans: additions, removals, renames and sidecar edits.
        watcher = FolderWatcher(url: folderURL) { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
    }

    private func startObservation() {
        observation?.cancel()
        let stream = store.observeItems(inFolder: id, query: query)
        observation = Task { [weak self] in
            do {
                for try await items in stream {
                    guard let self else { return }
                    apply(items)
                    isLoaded = true
                }
            } catch {
                self?.logger.error("Catalog observation ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Lists the folder again and reads the headers that are missing. Safe to call while a scan runs.
    public func rescan() {
        guard scan == nil else {
            rescanRequested = true
            return
        }
        isScanning = true
        scan = Task { [weak self] in
            await self?.runScan()
            guard let self else { return }
            scan = nil
            isScanning = false
            if rescanRequested {
                rescanRequested = false
                rescan()
            }
        }
    }

    private func runScan() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await FolderIndexer(store: store).index(folder: folder, at: folderURL)
            loadError = nil
            lastLoadDuration = clock.now - start
            subfolders = try await FolderNode.tree(fromFilePaths: store.relativePaths(inFolder: id))
            try await MetadataIndexer(store: store).run(folder: folder, at: folderURL) { [weak self] in
                await self?.currentPrioritized() ?? []
            }
        } catch {
            loadError = error.localizedDescription
            logger.error("Scan of \(self.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(_ items: [CatalogItem]) {
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        assets = AssetCollection(items.map(LibraryAsset.init))
        prioritized.subtract(items.filter { !$0.needsMetadata }.map(\.id))
    }

    public func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        guard let uuid = UUID(uuidString: id), let item = itemsByID[uuid] else { return nil }
        return LibraryAsset(item)
    }

    public func prioritize(_ asset: LibraryAsset) {
        guard let uuid = UUID(uuidString: asset.id), itemsByID[uuid]?.needsMetadata == true else { return }
        prioritized.insert(uuid)
    }

    private func currentPrioritized() -> Set<UUID> {
        prioritized
    }

    // MARK: - Images

    private func fileURL(for asset: LibraryAsset) -> URL? {
        guard let uuid = UUID(uuidString: asset.id), let item = itemsByID[uuid] else { return nil }
        return folderURL.appendingPathComponent(item.relativePath)
    }

    /// Edited photos: the thumbnail is cut from the cached preview of the real render; a missing preview
    /// is rebuilt once in the background. Others: Quick Look on the original.
    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) async -> CGImage? {
        guard let url = fileURL(for: asset) else { return nil }
        if asset.hasEdit {
            let cache = previewCache
            let fromCache = { @Sendable in await Task.detached { cache.thumbnail(for: asset, pixelSize: pixelSize) }.value }
            if let cached = await fromCache() {
                return cached
            }
            if await rebuildPreview(for: asset), let rebuilt = await fromCache() {
                return rebuilt
            }
        }
        return await FileImageLoader.thumbnail(at: url, pixelSize: pixelSize)
    }

    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        guard let url = fileURL(for: asset) else { return nil }
        return await Task.detached(priority: .userInitiated) { FileImageLoader.fullSizeImage(at: url) }.value
    }

    // MARK: - Decisions (sidecar first, catalog second)

    public func setRating(_ rating: Int, for asset: LibraryAsset) async throws {
        try await updateSidecar(for: asset) { sidecar, item in
            sidecar.rating = rating
            item.rating = sidecar.rating
        }
        logger.notice("Rated \(asset.id, privacy: .public) with \(rating) stars")
    }

    public func setFlag(_ flag: ItemFlag, for asset: LibraryAsset) async throws {
        try await updateSidecar(for: asset) { sidecar, item in
            sidecar.flag = flag
            item.flag = flag
        }
    }

    public func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws {
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try await updateSidecar(for: asset) { sidecar, item in
            sidecar.keywords = cleaned
            item.keywords = cleaned
        }
    }

    public func resourceInfo(for asset: LibraryAsset) async -> AssetResourceInfo {
        AssetResourceInfo(isRAW: asset.isRAW, hasJPEGTwin: asset.pairedAssetID != nil, originalFileName: fileURL(for: asset)?.lastPathComponent)
    }

    public func editingInput(for asset: LibraryAsset) async throws -> EditingInput {
        guard let url = fileURL(for: asset) else { throw LibrarySourceError.assetUnavailable }
        let recipeData = await Task.detached { try? Sidecar.read(forImageAt: url)?.recipeData }.value
        return EditingInput(imageURL: url, recipeData: recipeData)
    }

    /// Writes the recipe into the sidecar and caches a preview of the render. The recipe is the edit;
    /// the original stays the only pixel file in the folder.
    public func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws {
        let cache = previewCache
        if output.isReset {
            try await updateSidecar(for: asset) { sidecar, item in
                sidecar.recipeData = nil
                item.hasEdit = false
            }
            await Task.detached { cache.removePreviews(for: asset.id) }.value
            logger.notice("Removed recipe of \(asset.id, privacy: .public)")
            return
        }
        let updated = try await updateSidecar(for: asset) { sidecar, item in
            sidecar.recipeData = output.recipeData
            item.hasEdit = true
        }
        do {
            try await Task.detached { try cache.store(renderedJPEG: output.renderedJPEG, for: updated) }.value
        } catch {
            throw LibrarySourceError.editingFailed(error.localizedDescription)
        }
        logger.notice("Saved recipe of \(asset.id, privacy: .public)")
    }

    /// Reads the sidecar (or starts one carrying the item's identifier), lets `change` edit it together
    /// with the catalog item, writes the sidecar, then saves the item with the sidecar's new date.
    @discardableResult
    private func updateSidecar(for asset: LibraryAsset, change: (inout Sidecar, inout CatalogItem) -> Void) async throws -> LibraryAsset {
        guard let uuid = UUID(uuidString: asset.id), var item = itemsByID[uuid], let url = fileURL(for: asset) else {
            throw LibrarySourceError.assetUnavailable
        }
        // An unreadable sidecar (older format) is replaced rather than migrated.
        var sidecar = await Task.detached { try? Sidecar.read(forImageAt: url) }.value ?? Sidecar(id: uuid)
        change(&sidecar, &item)
        do {
            try sidecar.write(forImageAt: url)
        } catch {
            throw LibrarySourceError.editingFailed(error.localizedDescription)
        }
        // The sidecar's own date is the key of the preview cache and what the indexer compares against.
        item.sidecarModified = sidecar.isEmpty ? nil
            : try? Sidecar.url(for: url).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await store.save(item)
        itemsByID[uuid] = item
        return LibraryAsset(item)
    }

    /// Renders and stores the preview of an edited photo whose cache entry is missing. Returns false when
    /// no renderer is available, the render fails, or a rebuild is already running.
    private func rebuildPreview(for asset: LibraryAsset) async -> Bool {
        guard let previewRenderer, !previewsInProgress.contains(asset.id) else { return false }
        previewsInProgress.insert(asset.id)
        defer { previewsInProgress.remove(asset.id) }
        let cache = previewCache
        do {
            let input = try await editingInput(for: asset)
            guard let recipeData = input.recipeData else { return false }
            let jpeg = try await previewRenderer(input, recipeData)
            try await Task.detached { try cache.store(renderedJPEG: jpeg, for: asset) }.value
            logger.notice("Rebuilt preview of \(asset.id, privacy: .public)")
            return true
        } catch {
            logger.error("Preview rebuild failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

nonisolated extension LibraryAsset {
    /// The grid's view of a catalog item. The identifier is the item's UUID.
    init(_ item: CatalogItem) {
        self.init(
            id: item.id.uuidString,
            pixelWidth: item.pixelWidth ?? 0,
            pixelHeight: item.pixelHeight ?? 0,
            creationDate: item.captureDate ?? item.contentModified,
            isFavorite: false,
            rating: item.rating,
            flag: item.flag,
            keywords: item.keywords,
            modificationDate: item.sidecarModified ?? item.contentModified,
            hasEdit: item.hasEdit,
            isRAW: item.isRAW,
            pairedAssetID: item.pairedItemID?.uuidString
        )
    }
}
