import CoreGraphics
import Foundation
import Observation
import Photos

/// Source « photothèque Apple » : liste les photos et fournit leurs images via PhotoKit.
///
/// Première brique du POC. Le suivi des changements de la photothèque viendra avec le MVP.
@Observable
public final class PhotosLibrarySource {
    public private(set) var assets: [LibraryAsset] = []
    public private(set) var access: PhotoLibraryAccess = .current

    private var fetchResult: PHFetchResult<PHAsset>?
    private var assetsByID: [String: PHAsset] = [:]
    private let imageManager = PHCachingImageManager()

    public init() {}

    /// Demande l'accès si nécessaire puis charge les photos, les plus récentes d'abord.
    /// - Parameter limit: nombre maximal de photos à lister (0 = toutes).
    public func load(limit: Int = 0) async {
        access = await PhotoLibraryAccess.request()
        guard access == .authorized || access == .limited else {
            assets = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        if limit > 0 { options.fetchLimit = limit }

        let result = PHAsset.fetchAssets(with: options)
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
                isFavorite: asset.isFavorite
            ))
        }
        assetsByID = byID
        assets = listed
    }

    /// Vignette adaptée à l'affichage, en pixels (penser au facteur d'échelle de l'écran).
    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) async -> CGImage? {
        await requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill)
    }

    /// Image en pleine résolution, telle que Photos la fournit (ajustements Photos inclus).
    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        await requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit)
    }

    /// Prépare le cache de vignettes pour les photos qui vont apparaître à l'écran.
    public func prefetchThumbnails(for assets: [LibraryAsset], pixelSize: CGSize) {
        let phAssets = assets.compactMap { assetsByID[$0.id] }
        imageManager.startCachingImages(for: phAssets, targetSize: pixelSize, contentMode: .aspectFill, options: Self.requestOptions())
    }

    private func requestImage(for asset: LibraryAsset, targetSize: CGSize, contentMode: PHImageContentMode) async -> CGImage? {
        guard let phAsset = assetsByID[asset.id] else { return nil }
        let options = Self.requestOptions()
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(for: phAsset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                // En mode haute qualité, PhotoKit n'appelle ce bloc qu'une fois, sauf annulation.
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
