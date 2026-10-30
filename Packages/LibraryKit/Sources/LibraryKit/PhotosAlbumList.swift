import Foundation
import Observation
import OSLog
import Photos

/// An album of the Photos library, as the sidebar shows it.
public nonisolated struct PhotosAlbum: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable {
        case user
        case favorites
    }

    /// PhotoKit local identifier of the collection.
    public let id: String
    public let title: String
    public let kind: Kind
    /// PhotoKit's estimate; -1 when unknown.
    public let estimatedCount: Int
}

/// The user's albums plus the Favorites smart album, kept in sync with the library.
@Observable
public final class PhotosAlbumList {
    public private(set) var albums: [PhotosAlbum] = []
    public private(set) var isLoaded = false

    private var userAlbums: PHFetchResult<PHAssetCollection>?
    private var smartAlbums: PHFetchResult<PHAssetCollection>?
    private var changeRelay: PhotoLibraryChangeRelay?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosAlbumList")

    public init() {}

    /// Lists the albums; call once access to the library is granted.
    public func load() {
        guard userAlbums == nil else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        rebuild()
        changeRelay = PhotoLibraryChangeRelay { [weak self] change in
            self?.handle(change)
        }
        logger.notice("Listed \(self.albums.count) albums")
    }

    private func handle(_ change: PHChange) {
        var changed = false
        if let userAlbums, let details = change.changeDetails(for: userAlbums) {
            self.userAlbums = details.fetchResultAfterChanges
            changed = true
        }
        if let smartAlbums, let details = change.changeDetails(for: smartAlbums) {
            self.smartAlbums = details.fetchResultAfterChanges
            changed = true
        }
        if changed {
            rebuild()
        }
    }

    private func rebuild() {
        var list: [PhotosAlbum] = []
        smartAlbums?.enumerateObjects { collection, _, _ in
            list.append(PhotosAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Favorites",
                                    kind: .favorites, estimatedCount: collection.estimatedAssetCount))
        }
        userAlbums?.enumerateObjects { collection, _, _ in
            list.append(PhotosAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album",
                                    kind: .user, estimatedCount: collection.estimatedAssetCount))
        }
        albums = list
        isLoaded = true
    }
}
