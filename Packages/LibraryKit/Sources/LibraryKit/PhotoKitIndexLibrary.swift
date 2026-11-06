import Foundation
import OSLog
import Photos

/// The Apple Photos library as the index reads it. Everything comes from PhotoKit's database, never
/// from the originals, most of which may only be in iCloud.
public nonisolated struct PhotoKitIndexLibrary: PhotosIndexLibrary {
    /// Objects are faulted and released by slices, to keep memory flat on large libraries.
    private static let sliceSize = 2000

    public init() {}

    public func assetIDs() async -> [String] {
        Self.identifiers(of: PHAsset.fetchAssets(with: Self.imageOptions()))
    }

    /// Photos maintains a "RAW" smart album; measured against the resources of 2,000 assets and the file
    /// names of 74,000, it holds exactly the assets with a RAW original or alternate.
    public func rawAssetIDs() async -> Set<String> {
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumRAW, options: nil)
        guard let album = albums.firstObject else { return [] }
        return Set(Self.identifiers(of: PHAsset.fetchAssets(in: album, options: Self.imageOptions())))
    }

    /// One fetch for the whole batch, extended metadata included: 0.4 ms per asset, against 0.8 ms on
    /// demand and 2.7 ms through `PHAssetResource`.
    public func readings(for ids: [String]) async -> [PhotosAssetReading] {
        let options = Self.imageOptions()
        options.prefetchAssetExtendedMetadata = true
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        var readings: [PhotosAssetReading] = []
        readings.reserveCapacity(result.count)
        Self.forEachAsset(in: result) { asset in
            let metadata = asset.extendedMetadata
            readings.append(PhotosAssetReading(id: asset.localIdentifier, fileName: metadata.originalFilename,
                                               captureDate: asset.creationDate, keywords: metadata.keywords))
        }
        return readings
    }

    public func currentChangeToken() async -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true)
    }

    public func changes(since token: Data) async throws -> PhotosLibraryChanges {
        guard var last = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token) else {
            throw PhotosIndexError.unreadableChangeToken
        }
        var upserted: Set<String> = []
        var deleted: Set<String> = []
        // Throws when the token is older than the history Photos keeps: the caller rebuilds.
        for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: last) {
            let details = try change.changeDetails(for: .asset)
            upserted.formUnion(details.insertedLocalIdentifiers)
            upserted.formUnion(details.updatedLocalIdentifiers)
            upserted.subtract(details.deletedLocalIdentifiers)
            deleted.formUnion(details.deletedLocalIdentifiers)
            last = change.changeToken
        }
        return try PhotosLibraryChanges(upserted: upserted, deleted: deleted,
                                        token: NSKeyedArchiver.archivedData(withRootObject: last, requiringSecureCoding: true))
    }

    public func changeNotifications() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let relay = PersistentChangesRelay { continuation.yield() }
            // The library holds its observers weakly: the stream keeps the relay alive until it ends.
            continuation.onTermination = { _ in relay.stop() }
        }
    }

    // MARK: - Private

    private static func imageOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    private static func identifiers(of result: PHFetchResult<PHAsset>) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        forEachAsset(in: result) { ids.append($0.localIdentifier) }
        return ids
    }

    private static func forEachAsset(in result: PHFetchResult<PHAsset>, _ body: (PHAsset) -> Void) {
        let count = result.count
        for start in stride(from: 0, to: count, by: sliceSize) {
            autoreleasepool {
                result.objects(at: IndexSet(integersIn: start ..< min(start + sliceSize, count))).forEach(body)
            }
        }
    }
}

/// Errors of the Photos index.
public nonisolated enum PhotosIndexError: Error, LocalizedError, Sendable {
    case unreadableChangeToken

    public var errorDescription: String? {
        switch self {
        case .unreadableChangeToken: "The saved position in the photo library's history can't be read."
        }
    }
}

/// Bridges PhotoKit's persistent change notifications (macOS 27, delivered on an arbitrary serial queue)
/// to a closure. They cover changes made by any app, and pair with `fetchPersistentChanges(since:)`.
private final nonisolated class PersistentChangesRelay: NSObject, PHPhotoLibraryPersistentChangesObserver, Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    func stop() {
        PHPhotoLibrary.shared().unregisterPersistentChangesObserver(self)
    }

    func photoLibraryPersistentChangesDidUpdate(_: PHPhotoLibrary) {
        handler()
    }
}
