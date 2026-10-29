import CoreGraphics
import Foundation
import Observation
import OSLog
import Photos

/// "Apple Photos library" source: lists photos and provides their images through PhotoKit.
///
/// Keeps the list in sync with the library through `PHPhotoLibraryChangeObserver`.
@Observable
public final class PhotosLibrarySource {
    public private(set) var assets: [LibraryAsset] = []
    public private(set) var access: PhotoLibraryAccess = .current
    /// Duration of the last full listing, for performance tracking.
    public private(set) var lastLoadDuration: Duration?

    private var fetchResult: PHFetchResult<PHAsset>?
    private var assetsByID: [String: PHAsset] = [:]
    private let imageManager = PHCachingImageManager()
    private var changeRelay: PhotoLibraryChangeRelay?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosLibrarySource")

    public init() {}

    /// Requests access if needed, then loads the photos, newest first, and starts tracking changes.
    /// - Parameter limit: maximum number of photos to list (0 = all).
    public func load(limit: Int = 0) async {
        access = await PhotoLibraryAccess.request()
        logger.notice("Photo library access: \(String(describing: self.access), privacy: .public)")
        guard access == .authorized || access == .limited else {
            assets = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if limit > 0 {
            options.fetchLimit = limit
        }

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

    // MARK: - Private

    private func handle(_ change: PHChange) {
        guard let fetchResult, let details = change.changeDetails(for: fetchResult) else { return }
        let clock = ContinuousClock()
        let start = clock.now
        apply(fetchResult: details.fetchResultAfterChanges)
        logger.notice("Applied library change (\(details.insertedObjects.count) inserted, \(details.removedObjects.count) removed, \(details.changedObjects.count) changed) in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Rebuilds the lightweight asset list from a fetch result. Linear in the library size; measured by `lastLoadDuration`.
    private func apply(fetchResult result: PHFetchResult<PHAsset>) {
        fetchResult = result
        var listed: [LibraryAsset] = []
        var byID: [String: PHAsset] = [:]
        listed.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
            listed.append(LibraryAsset(
                id: asset.localIdentifier,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite,
                rating: asset.rating.rawValue
            ))
        }
        assetsByID = byID
        assets = listed
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
