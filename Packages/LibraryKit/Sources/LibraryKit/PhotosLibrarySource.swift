import CoreGraphics
import Foundation
import ObjCSupport
import Observation
import OSLog
import Photos
import UniformTypeIdentifiers

/// "Apple Photos library" source: lists photos and provides their images through PhotoKit.
///
/// Keeps the list in sync with the library through `PHPhotoLibraryChangeObserver`.
@Observable
public final class PhotosLibrarySource: LibrarySource {
    public private(set) var assets: AssetCollection = .empty
    /// Bumped on every library change, so views reading a single asset refresh with the library.
    public private(set) var libraryVersion = 0
    public private(set) var access: PhotoLibraryAccess = .current
    /// Duration of the last full listing, for performance tracking.
    public private(set) var lastLoadDuration: Duration?

    public var displayName: String {
        album?.title ?? "Photos"
    }

    public var capabilities: Set<LibraryCapability> {
        [.rating, .keywords]
    }

    /// Date and favorite are native; rating filter and sort are too on macOS 27, confirmed by a probe at
    /// load time since PhotoKit doesn't document them. Flags don't exist in Photos; keywords can't be
    /// queried natively.
    public private(set) var queryCapabilities: Set<QueryCapability> = [.favorite]

    public var query = LibraryQuery.default {
        didSet {
            guard query != oldValue, fetchResult != nil else { return }
            refetch()
        }
    }

    private var fetchResult: PHFetchResult<PHAsset>?
    /// PHAssets fetched by identifier, kept for image requests and edits. Not observed: it is filled
    /// while views are being built, and mutating observed state there would invalidate them in a loop.
    @ObservationIgnored private var materialized: [String: PHAsset] = [:]
    /// Resource kinds per asset, found once per session; PhotoKit has no predicate for them.
    @ObservationIgnored private var resourceInfos: [String: AssetResourceInfo] = [:]
    private let imageManager = PHCachingImageManager()
    private var changeRelay: PhotoLibraryChangeRelay?
    /// Editing inputs kept alive while a photo is open: they hold the access to the original file.
    private var editingInputs: [String: PHContentEditingInput] = [:]
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosLibrarySource")

    /// The album this source shows, or nil for the whole library.
    public let album: PhotosAlbum?

    public init(album: PhotosAlbum? = nil) {
        self.album = album
    }

    /// Requests access if needed, then loads the photos, newest first, and starts tracking changes.
    public func load() async {
        guard fetchResult == nil else { return }
        access = await PhotoLibraryAccess.request()
        logger.notice("Photo library access: \(String(describing: self.access), privacy: .public)")
        guard access == .authorized || access == .limited else {
            assets = .empty
            return
        }

        probeNativeQueries()
        let clock = ContinuousClock()
        let start = clock.now
        apply(fetchResult: fetchAssets())
        lastLoadDuration = clock.now - start
        logger.notice("Fetched \(self.assets.count) photos in \(self.lastLoadDuration!.formatted(.units(allowed: [.milliseconds])), privacy: .public)")

        if changeRelay == nil {
            changeRelay = PhotoLibraryChangeRelay { [weak self] change in
                self?.handle(change)
            }
        }
    }

    /// Sets the star rating (0 to 5) of a photo, stored natively by Photos (macOS 27).
    /// The list is refreshed through the change observer once Photos commits the change.
    public func setRating(_ rating: Int, for asset: LibraryAsset) async throws {
        guard let phAsset = phAsset(for: asset.id),
              let value = PHAsset.Rating(rawValue: min(max(rating, 0), 5)) else { return }
        // PhotoKit runs the change block on its own queue, so it must not inherit the main-actor isolation
        // this module defaults to. PHAsset is an immutable, Sendable snapshot and is safe to hand over.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: phAsset).rating = value
        }
        logger.notice("Rated \(asset.id, privacy: .public) with \(rating) stars")
    }

    /// Photos stores a RAW + JPEG pair as one asset with two resources. Listing them costs one request per
    /// asset, so it happens for the tiles on screen only and the answer is cached.
    public func resourceInfo(for asset: LibraryAsset) async -> AssetResourceInfo {
        if let cached = resourceInfos[asset.id] {
            return cached
        }
        guard let phAsset = phAsset(for: asset.id) else { return AssetResourceInfo(asset) }
        let info = await Task.detached {
            let photos = PHAssetResource.assetResources(for: phAsset).filter { $0.type == .photo || $0.type == .alternatePhoto }
            let raw = photos.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
            let other = photos.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == false }
            let name = (photos.first { $0.type == .photo } ?? photos.first)?.originalFilename
            return AssetResourceInfo(isRAW: raw, hasJPEGTwin: raw && other, originalFileName: name)
        }.value
        resourceInfos[asset.id] = info
        return info
    }

    /// Keywords live in Photos' extended metadata, fetched per asset rather than for the whole listing.
    public func keywords(for asset: LibraryAsset) async -> [String] {
        guard let phAsset = phAsset(for: asset.id) else { return [] }
        return await Task.detached { phAsset.extendedMetadata.keywords }.value
    }

    public func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws {
        guard let phAsset = phAsset(for: asset.id) else { throw LibrarySourceError.assetUnavailable }
        let current = await Set(self.keywords(for: asset))
        let wanted = Set(keywords)
        let added = wanted.subtracting(current)
        let removed = current.subtracting(wanted)
        guard !added.isEmpty || !removed.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetChangeRequest(for: phAsset)
            added.forEach { request.addKeyword($0) }
            removed.forEach { request.removeKeyword($0) }
        }
        logger.notice("Keywords of \(asset.id, privacy: .public): +\(added.count) -\(removed.count)")
    }

    /// Thumbnail sized for display, in pixels (account for the screen's scale factor).
    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) async -> CGImage? {
        await requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill)
    }

    /// Full-resolution image as Photos delivers it (Photos adjustments included).
    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        await requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit)
    }

    /// Warms the thumbnail cache for photos about to appear on screen.
    /// Keeps PhotoKit's cache warm for a window of rows around what is on screen, and drops what scrolled
    /// far away. Called for every visible tile, so it only acts when the window moves by a few rows.
    public func prefetchThumbnails(around index: Int, pixelSize: CGSize) {
        guard let fetchResult else { return }
        let count = fetchResult.count
        guard count > 0 else { return }
        let desired = max(0, index - Self.prefetchWindow / 2) ..< min(count, index + Self.prefetchWindow)
        guard abs(desired.lowerBound - prefetched.lowerBound) >= Self.prefetchStep
            || abs(desired.upperBound - prefetched.upperBound) >= Self.prefetchStep
            || prefetched.isEmpty else { return }

        let options = Self.requestOptions()
        let toStart = desired.filter { !prefetched.contains($0) }.map { fetchResult.object(at: $0) }
        let toStop = prefetched.filter { !desired.contains($0) && $0 < count }.map { fetchResult.object(at: $0) }
        if !toStop.isEmpty {
            imageManager.stopCachingImages(for: toStop, targetSize: pixelSize, contentMode: .aspectFill, options: options)
        }
        if !toStart.isEmpty {
            imageManager.startCachingImages(for: toStart, targetSize: pixelSize, contentMode: .aspectFill, options: options)
        }
        prefetched = desired
    }

    /// Rows kept warm around the visible one, and how far the window must move before it is updated.
    private static let prefetchWindow = 60
    private static let prefetchStep = 10
    @ObservationIgnored private var prefetched: Range<Int> = 0 ..< 0

    // MARK: - Editing (PHAdjustmentData)

    /// Asks Photos for the original (RAW included) and for Qaama's own adjustment data, if the photo
    /// was last edited here. Edits made by other apps are baked into the image Photos hands back.
    public func editingInput(for asset: LibraryAsset) async throws -> EditingInput {
        guard let phAsset = phAsset(for: asset.id) else { throw LibrarySourceError.assetUnavailable }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { @Sendable data in data.formatIdentifier == EditingFormat.identifier }

        // PHContentEditingInput isn't Sendable; PhotoKit hands it over once and we only touch it on the main actor afterwards.
        let input = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedSendable<PHContentEditingInput>, Error>) in
            phAsset.requestContentEditingInput(with: options) { @Sendable input, info in
                if let input {
                    continuation.resume(returning: UncheckedSendable(input))
                } else {
                    let reason = (info[PHContentEditingInputErrorKey] as? NSError)?.localizedDescription ?? "no original available"
                    continuation.resume(throwing: LibrarySourceError.editingFailed(reason))
                }
            }
        }.value
        editingInputs[asset.id] = input
        let recipeData = input.adjustmentData?.formatIdentifier == EditingFormat.identifier ? input.adjustmentData?.data : nil
        logger.notice("Editing input for \(asset.id, privacy: .public): file \(input.fullSizeImageURL?.pathExtension ?? "none", privacy: .public), recipe \(recipeData != nil)")
        return EditingInput(imageURL: input.fullSizeImageURL, image: input.displaySizeImage?.asCGImage, recipeData: recipeData)
    }

    /// Stores the recipe as `PHAdjustmentData` and the rendered JPEG as the photo's current version,
    /// the standard non-destructive path: Photos keeps the original and can revert at any time.
    public func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws {
        guard let phAsset = phAsset(for: asset.id) else { throw LibrarySourceError.assetUnavailable }
        guard let input = editingInputs[asset.id] else { throw LibrarySourceError.editingFailed("the photo wasn't opened for editing") }
        if output.isReset {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest(for: phAsset).revertAssetContentToOriginal()
            }
            logger.notice("Reverted \(asset.id, privacy: .public) to its original in Photos")
            return
        }

        let editingOutput = PHContentEditingOutput(contentEditingInput: input)
        editingOutput.adjustmentData = PHAdjustmentData(
            formatIdentifier: EditingFormat.identifier,
            formatVersion: EditingFormat.version,
            data: output.recipeData
        )
        do {
            try output.renderedJPEG.write(to: editingOutput.renderedContentURL, options: .atomic)
        } catch {
            throw LibrarySourceError.editingFailed(error.localizedDescription)
        }
        // Same story as above: the output is built here and consumed once by PhotoKit's change block.
        nonisolated(unsafe) let pendingOutput = editingOutput
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: phAsset).contentEditingOutput = pendingOutput
        }
        logger.notice("Saved edit to Photos for \(asset.id, privacy: .public)")
    }

    /// Photos renders its thumbnails with the saved edit itself, so there is nothing to apply.
    public func savedRecipeData(for _: LibraryAsset) async -> Data? {
        nil
    }

    /// Releases the original file access once the editor closes.
    public func endEditing(_ asset: LibraryAsset) {
        editingInputs[asset.id] = nil
    }

    // MARK: - Private

    private func handle(_ change: PHChange) {
        guard let fetchResult, let details = change.changeDetails(for: fetchResult) else { return }
        // Nothing is materialized up front, so applying a change is just swapping the fetch result;
        // changed assets are dropped from the cache and re-read on their next access.
        for changed in details.changedObjects {
            materialized[changed.localIdentifier] = nil
            resourceInfos[changed.localIdentifier] = nil
        }
        for removed in details.removedObjects {
            materialized[removed.localIdentifier] = nil
        }
        apply(fetchResult: details.fetchResultAfterChanges)
        logger.notice("Applied library change (\(details.insertedObjects.count) inserted, \(details.removedObjects.count) removed, \(details.changedObjects.count) changed)")
    }

    /// What PhotoKit accepts natively isn't documented for ratings and keywords; an unsupported predicate
    /// raises an Objective-C exception, so each candidate is tried once behind a catcher.
    private func probeNativeQueries() {
        func accepts(_ configure: (PHFetchOptions) -> Void) -> Bool {
            let options = PHFetchOptions()
            options.fetchLimit = 1
            configure(options)
            var count = -1
            let exception = QAACatchException { count = PHAsset.fetchAssets(with: options).count }
            return exception == nil && count >= 0
        }
        var supported: Set<QueryCapability> = [.favorite]
        if accepts({ $0.predicate = NSPredicate(format: "rating >= %d", 1) }) {
            supported.insert(.rating)
        }
        if accepts({ $0.sortDescriptors = [NSSortDescriptor(key: "rating", ascending: false)] }) {
            supported.insert(.sortByRating)
        }
        queryCapabilities = supported
        logger.notice("PhotoKit native queries: rating filter \(supported.contains(.rating)), rating sort \(supported.contains(.sortByRating))")
    }

    /// All photos, or those of the album when this source is scoped to one.
    private func fetchAssets() -> PHFetchResult<PHAsset> {
        if let album, let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject {
            return PHAsset.fetchAssets(in: collection, options: fetchOptions())
        }
        return PHAsset.fetchAssets(with: fetchOptions())
    }

    /// Translates the query into PhotoKit's own sorting and predicates.
    private func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        switch query.sort {
        case .rating where queryCapabilities.contains(.sortByRating):
            options.sortDescriptors = [
                NSSortDescriptor(key: "rating", ascending: query.ascending),
                NSSortDescriptor(key: "creationDate", ascending: false),
            ]
        case .modificationDate:
            options.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: query.ascending)]
        default:
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: query.ascending)]
        }
        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if query.favoritesOnly {
            predicates.append(NSPredicate(format: "isFavorite == YES"))
        }
        if query.minimumRating > 0, queryCapabilities.contains(.rating) {
            predicates.append(NSPredicate(format: "rating >= %d", query.minimumRating))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return options
    }

    private func refetch() {
        probeNativeQueries()
        let clock = ContinuousClock()
        let start = clock.now
        apply(fetchResult: fetchAssets())
        logger.notice("Refetched \(self.assets.count) photos in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Exposes the fetch result as a lazy collection: a row is built only when the grid asks for it.
    private func apply(fetchResult result: PHFetchResult<PHAsset>) {
        fetchResult = result
        libraryVersion += 1
        // Indices moved: forget the warm window; the next visible tile rebuilds it.
        imageManager.stopCachingImagesForAllAssets()
        prefetched = 0 ..< 0
        // The row closure must stay free of side effects: SwiftUI may walk the whole collection.
        assets = AssetCollection(count: result.count) { index in
            Self.makeAsset(result.object(at: index))
        }
    }

    public func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        // Register the caller's dependency on the library: the cache below is not observed.
        _ = libraryVersion
        return phAsset(for: id).map(Self.makeAsset)
    }

    /// The PHAsset behind an identifier: from the rows already shown, or fetched on its own (a few ms).
    private func phAsset(for id: String) -> PHAsset? {
        if let cached = materialized[id] {
            return cached
        }
        guard let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        materialized[id] = fetched
        return fetched
    }

    private static func makeAsset(_ asset: PHAsset) -> LibraryAsset {
        LibraryAsset(
            id: asset.localIdentifier,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            isFavorite: asset.isFavorite,
            rating: asset.rating.rawValue,
            modificationDate: asset.modificationDate,
            hasEdit: asset.hasAdjustments
        )
    }

    private func requestImage(for asset: LibraryAsset, targetSize: CGSize, contentMode: PHImageContentMode) async -> CGImage? {
        guard let phAsset = phAsset(for: asset.id) else { return nil }
        let options = Self.requestOptions()
        return await withCheckedContinuation { continuation in
            // Delivered on an arbitrary queue: the handler must stay out of the main-actor isolation this module defaults to.
            imageManager.requestImage(for: phAsset, targetSize: targetSize, contentMode: contentMode, options: options) { @Sendable image, info in
                // In high-quality delivery mode PhotoKit calls this block once, unless the request is cancelled.
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image?.asCGImage)
            }
        }
    }

    private static func requestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return options
    }
}
