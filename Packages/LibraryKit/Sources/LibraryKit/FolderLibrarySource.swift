import CoreGraphics
import Foundation
import ImageIOKit
import Observation
import OSLog

/// "Folder on disk" source: lists the image files below a folder chosen by the user.
///
/// Holds the security-scoped access to the folder for as long as it lives.
@Observable
public final class FolderLibrarySource: LibrarySource, Identifiable {
    public let id: UUID
    public let folderURL: URL
    public private(set) var assets: [LibraryAsset] = []
    public private(set) var lastLoadDuration: Duration?
    public private(set) var isLoaded = false
    /// Message to show when the folder could not be listed.
    public private(set) var loadError: String?

    public var displayName: String {
        folderURL.lastPathComponent
    }

    public var canRate: Bool {
        false
    }

    /// Rebuilds the preview of an edited photo when the cache has none. Set by the catalog.
    public var previewRenderer: PreviewRenderer?

    private let hasSecurityScope: Bool
    private let previewCache: PreviewCache
    private var previewsInProgress: Set<LibraryAsset.ID> = []
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FolderLibrarySource")

    public init(folderURL: URL, id: UUID = UUID(), previewCache: PreviewCache = PreviewCache()) {
        self.id = id
        self.folderURL = folderURL
        self.previewCache = previewCache
        hasSecurityScope = folderURL.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope {
            folderURL.stopAccessingSecurityScopedResource()
        }
    }

    public func load() async {
        guard !isLoaded else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let folder = folderURL
        do {
            assets = try await Task.detached(priority: .userInitiated) { try FolderScanner.scan(folder) }.value
            loadError = nil
        } catch {
            assets = []
            loadError = error.localizedDescription
        }
        isLoaded = true
        lastLoadDuration = clock.now - start
        logger.notice("Listed \(self.assets.count) files in \(self.folderURL.lastPathComponent, privacy: .public) in \(self.lastLoadDuration!.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Forgets the listing so the next `load()` scans the folder again.
    public func invalidate() {
        isLoaded = false
    }

    /// Edited photos: the thumbnail is cut from the cached preview of the real render; a missing preview
    /// is rebuilt once in the background. Others: Quick Look on the original.
    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) async -> CGImage? {
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
        return await FileImageLoader.thumbnail(at: URL(filePath: asset.id), pixelSize: pixelSize)
    }

    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        let url = URL(filePath: asset.id)
        return await Task.detached(priority: .userInitiated) { FileImageLoader.fullSizeImage(at: url) }.value
    }

    /// Ratings for files will live in a sidecar; not part of this building block yet.
    public func setRating(_: Int, for _: LibraryAsset) async throws {
        throw LibrarySourceError.ratingUnsupported
    }

    // MARK: - Editing (sidecar file next to the image)

    public func editingInput(for asset: LibraryAsset) async throws -> EditingInput {
        let url = URL(filePath: asset.id)
        let recipeData = await Task.detached { try? Sidecar.read(forImageAt: url)?.recipeData }.value
        return EditingInput(imageURL: url, recipeData: recipeData)
    }

    /// Writes the recipe as `<image name>.qaama` next to the image and caches a preview of the render.
    /// The recipe is the edit; the original stays the only pixel file in the folder.
    public func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws {
        let imageURL = URL(filePath: asset.id)
        let sidecarURL = Sidecar.url(for: imageURL)
        let cache = previewCache
        // Keep the other decisions (rating, flag, keywords) stored in the sidecar; only the recipe changes.
        // An unreadable sidecar (older format) is replaced rather than migrated.
        var sidecar = await Task.detached { try? Sidecar.read(forImageAt: imageURL) }.value ?? Sidecar()
        if output.isReset {
            sidecar.recipeData = nil
            try? sidecar.write(forImageAt: imageURL)
            await Task.detached { cache.removePreviews(for: asset.id) }.value
            logger.notice("Removed recipe from \(sidecarURL.lastPathComponent, privacy: .public)")
            update(asset.withEdit(false, at: .now))
            return
        }
        let updated: LibraryAsset
        do {
            sidecar.recipeData = output.recipeData
            try sidecar.write(forImageAt: imageURL)
            // The sidecar's own date is the key: the scanner will read the same one on the next launch.
            let date = try sidecarURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .now
            updated = asset.withEdit(true, at: date)
            try await Task.detached { try cache.store(renderedJPEG: output.renderedJPEG, for: updated) }.value
        } catch {
            throw LibrarySourceError.editingFailed(error.localizedDescription)
        }
        logger.notice("Saved recipe to \(sidecarURL.lastPathComponent, privacy: .public)")
        update(updated)
    }

    private func update(_ asset: LibraryAsset) {
        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[index] = asset
        }
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
            logger.notice("Rebuilt preview for \(URL(filePath: asset.id).lastPathComponent, privacy: .public)")
            return true
        } catch {
            logger.error("Preview rebuild failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
