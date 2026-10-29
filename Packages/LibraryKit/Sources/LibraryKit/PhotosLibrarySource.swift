import CoreGraphics
import Foundation
import Observation
import OSLog
import Photos

/// "Apple Photos library" source: lists photos and provides their images through PhotoKit.
///
/// Keeps the list in sync with the library through `PHPhotoLibraryChangeObserver`.
@Observable
public final class PhotosLibrarySource: LibrarySource {
    public private(set) var assets: [LibraryAsset] = []
    public private(set) var access: PhotoLibraryAccess = .current
    /// Duration of the last full listing, for performance tracking.
    public private(set) var lastLoadDuration: Duration?

    public var displayName: String {
        "Photos"
    }

    public var capabilities: Set<LibraryCapability> {
        [.rating, .keywords]
    }

    private var fetchResult: PHFetchResult<PHAsset>?
    private var assetsByID: [String: PHAsset] = [:]
    private let imageManager = PHCachingImageManager()
    private var changeRelay: PhotoLibraryChangeRelay?
    /// Editing inputs kept alive while a photo is open: they hold the access to the original file.
    private var editingInputs: [String: PHContentEditingInput] = [:]
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosLibrarySource")

    public init() {}

    /// Requests access if needed, then loads the photos, newest first, and starts tracking changes.
    public func load() async {
        guard fetchResult == nil else { return }
        access = await PhotoLibraryAccess.request()
        logger.notice("Photo library access: \(String(describing: self.access), privacy: .public)")
        guard access == .authorized || access == .limited else {
            assets = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let clock = ContinuousClock()
        let start = clock.now
        let result = PHAsset.fetchAssets(with: options)
        apply(fetchResult: result)
        lastLoadDuration = clock.now - start
        logger.notice("Listed \(self.assets.count) photos in \(self.lastLoadDuration!.formatted(.units(allowed: [.milliseconds])), privacy: .public)")

        if changeRelay == nil {
            changeRelay = PhotoLibraryChangeRelay { [weak self] change in
                self?.handle(change)
            }
        }
    }

    /// Sets the star rating (0 to 5) of a photo, stored natively by Photos (macOS 27).
    /// The list is refreshed through the change observer once Photos commits the change.
    public func setRating(_ rating: Int, for asset: LibraryAsset) async throws {
        guard let phAsset = assetsByID[asset.id],
              let value = PHAsset.Rating(rawValue: min(max(rating, 0), 5)) else { return }
        // PhotoKit runs the change block on its own queue, so it must not inherit the main-actor isolation
        // this module defaults to. PHAsset is an immutable, Sendable snapshot and is safe to hand over.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: phAsset).rating = value
        }
        logger.notice("Rated \(asset.id, privacy: .public) with \(rating) stars")
        // Reflect the new rating right away; the change observer confirms it a moment later.
        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[index].rating = value.rawValue
        }
    }

    /// Keywords live in Photos' extended metadata, fetched per asset rather than for the whole listing.
    public func keywords(for asset: LibraryAsset) async -> [String] {
        guard let phAsset = assetsByID[asset.id] else { return [] }
        return await Task.detached { phAsset.extendedMetadata.keywords }.value
    }

    public func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws {
        guard let phAsset = assetsByID[asset.id] else { throw LibrarySourceError.assetUnavailable }
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
    public func prefetchThumbnails(for assets: [LibraryAsset], pixelSize: CGSize) {
        let phAssets = assets.compactMap { assetsByID[$0.id] }
        imageManager.startCachingImages(for: phAssets, targetSize: pixelSize, contentMode: .aspectFill, options: Self.requestOptions())
    }

    // MARK: - Editing (PHAdjustmentData)

    /// Asks Photos for the original (RAW included) and for Qaama's own adjustment data, if the photo
    /// was last edited here. Edits made by other apps are baked into the image Photos hands back.
    public func editingInput(for asset: LibraryAsset) async throws -> EditingInput {
        guard let phAsset = assetsByID[asset.id] else { throw LibrarySourceError.assetUnavailable }
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
        guard let phAsset = assetsByID[asset.id] else { throw LibrarySourceError.assetUnavailable }
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
        let clock = ContinuousClock()
        let start = clock.now
        if !applyIncrementally(details) {
            apply(fetchResult: details.fetchResultAfterChanges)
        }
        logger.notice("Applied library change (\(details.insertedObjects.count) inserted, \(details.removedObjects.count) removed, \(details.changedObjects.count) changed) in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Patches only the rows whose attributes changed (rating, favorite…), which is the common case after
    /// an edit. Returns false when photos were added, removed or reordered, so the caller rebuilds the list.
    private func applyIncrementally(_ details: PHFetchResultChangeDetails<PHAsset>) -> Bool {
        guard details.hasIncrementalChanges, !details.hasMoves,
              details.insertedIndexes?.isEmpty ?? true,
              details.removedIndexes?.isEmpty ?? true,
              let changedIndexes = details.changedIndexes else { return false }
        let result = details.fetchResultAfterChanges
        guard result.count == assets.count else { return false }
        var updated = assets
        for index in changedIndexes {
            let phAsset = result.object(at: index)
            guard updated[index].id == phAsset.localIdentifier else { return false }
            assetsByID[phAsset.localIdentifier] = phAsset
            updated[index] = Self.makeAsset(phAsset)
        }
        fetchResult = result
        assets = updated
        return true
    }

    /// Rebuilds the lightweight asset list from a fetch result. Linear in the library size; measured by `lastLoadDuration`.
    private func apply(fetchResult result: PHFetchResult<PHAsset>) {
        fetchResult = result
        var listed: [LibraryAsset] = []
        var byID: [String: PHAsset] = [:]
        listed.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
            listed.append(Self.makeAsset(asset))
        }
        assetsByID = byID
        assets = listed
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
        guard let phAsset = assetsByID[asset.id] else { return nil }
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
