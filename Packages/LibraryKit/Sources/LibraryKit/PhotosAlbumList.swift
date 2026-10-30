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

/// A node of the user's album hierarchy: an album, or a folder of albums and folders.
public nonisolated enum PhotosAlbumNode: Hashable, Sendable, Identifiable {
    case album(PhotosAlbum)
    case folder(id: String, title: String, children: [PhotosAlbumNode])

    public var id: String {
        switch self {
        case let .album(album): album.id
        case let .folder(id, _, _): id
        }
    }

    public var title: String {
        switch self {
        case let .album(album): album.title
        case let .folder(_, title, _): title
        }
    }

    /// Nil for albums, so `OutlineGroup` treats them as leaves.
    public var children: [PhotosAlbumNode]? {
        if case let .folder(_, _, children) = self {
            return children
        }
        return nil
    }
}

/// The user's albums in their folder hierarchy, plus the Favorites smart album, kept in sync with
/// the library.
@Observable
public final class PhotosAlbumList {
    /// Every album, flat, for lookups by identifier.
    public private(set) var albums: [PhotosAlbum] = []
    /// The user's folders and albums as Photos organizes them.
    public private(set) var tree: [PhotosAlbumNode] = []
    public private(set) var favorites: PhotosAlbum?
    public private(set) var isLoaded = false

    /// Every fetch result the tree was built from; a change in any of them rebuilds the tree.
    private var fetchResults: [PHFetchResult<PHCollection>] = []
    private var smartAlbums: PHFetchResult<PHAssetCollection>?
    private var changeRelay: PhotoLibraryChangeRelay?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosAlbumList")

    public init() {}

    /// Lists the albums; call once access to the library is granted.
    public func load() {
        guard !isLoaded else { return }
        smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        rebuild()
        changeRelay = PhotoLibraryChangeRelay { [weak self] change in
            self?.handle(change)
        }
    }

    private func handle(_ change: PHChange) {
        var changed = false
        if let smartAlbums, let details = change.changeDetails(for: smartAlbums) {
            self.smartAlbums = details.fetchResultAfterChanges
            changed = true
        }
        if fetchResults.contains(where: { change.changeDetails(for: $0) != nil }) {
            changed = true
        }
        if changed {
            rebuild()
        }
    }

    private func rebuild() {
        let clock = ContinuousClock()
        let start = clock.now
        var flat: [PhotosAlbum] = []
        var results: [PHFetchResult<PHCollection>] = []

        func nodes(of result: PHFetchResult<PHCollection>) -> [PhotosAlbumNode] {
            results.append(result)
            var list: [PhotosAlbumNode] = []
            result.enumerateObjects { collection, _, _ in
                if let album = collection as? PHAssetCollection {
                    let item = PhotosAlbum(id: album.localIdentifier, title: album.localizedTitle ?? "Album",
                                           kind: .user, estimatedCount: album.estimatedAssetCount)
                    flat.append(item)
                    list.append(.album(item))
                } else if let folder = collection as? PHCollectionList {
                    let children = nodes(of: PHCollectionList.fetchCollections(in: folder, options: Self.sortedByTitle))
                    list.append(.folder(id: folder.localIdentifier, title: folder.localizedTitle ?? "Folder", children: children))
                }
            }
            // Folders first, then albums, each group by title, as Photos does.
            return list.sorted { lhs, rhs in
                let lhsFolder = lhs.children != nil, rhsFolder = rhs.children != nil
                if lhsFolder != rhsFolder {
                    return lhsFolder
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }

        tree = nodes(of: PHCollectionList.fetchTopLevelUserCollections(with: Self.sortedByTitle))
        fetchResults = results
        var favorite: PhotosAlbum?
        smartAlbums?.enumerateObjects { collection, _, _ in
            // Smart albums report NSNotFound as their estimate; counting the favorites is cheap.
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            favorite = PhotosAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Favorites",
                                   kind: .favorites, estimatedCount: count)
        }
        favorites = favorite
        albums = (favorite.map { [$0] } ?? []) + flat
        isLoaded = true
        logger.notice("Listed \(flat.count) albums in \(results.count) folders in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    private static var sortedByTitle: PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        return options
    }
}
