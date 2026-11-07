import Foundation
import os
import OSLog
import Photos

/// Album management in the Apple Photos library, through PhotoKit change requests. Albums are lists of
/// references: none of this touches a photo or its original.
public nonisolated struct PhotoKitAlbumLibrary: PhotosAlbumLibrary {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotoKitAlbumLibrary")

    public init() {}

    public func createAlbum(_ content: PhotosAlbumContent) async throws -> String {
        let folder = try content.folderID.map { try Self.folder($0, allowing: .addContent) }
        let assets = Self.assets(content.assetIDs)
        // The identifier is only known inside the change block, which PhotoKit runs on its own queue.
        let created = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await Self.perform {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: content.title)
            if !assets.isEmpty {
                request.addAssets(assets as NSArray)
            }
            let placeholder = request.placeholderForCreatedAssetCollection
            if let folder {
                PHCollectionListChangeRequest(for: folder)?.addChildCollections([placeholder] as NSArray)
            }
            created.withLock { $0 = placeholder.localIdentifier }
        }
        guard let id = created.withLock({ $0 }) else { throw PhotosAlbumError.changeFailed("no album was created") }
        Self.logger.notice("Created album \(id, privacy: .public) with \(assets.count) photos")
        return id
    }

    public func createFolder(titled title: String, inFolder parentID: String?) async throws -> String {
        let parent = try parentID.map { try Self.folder($0, allowing: .addContent) }
        let created = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await Self.perform {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            let placeholder = request.placeholderForCreatedCollectionList
            if let parent {
                PHCollectionListChangeRequest(for: parent)?.addChildCollections([placeholder] as NSArray)
            }
            created.withLock { $0 = placeholder.localIdentifier }
        }
        guard let id = created.withLock({ $0 }) else { throw PhotosAlbumError.changeFailed("no folder was created") }
        Self.logger.notice("Created album folder \(id, privacy: .public)")
        return id
    }

    public func albumContent(id: String) async throws -> PhotosAlbumContent {
        let album = try Self.album(id)
        // Only a user folder can be given back to `createAlbum`; other lists holding the album don't count.
        let parent = PHCollectionList.fetchCollectionListsContaining(album, options: nil).firstObject
        let folderID = parent.flatMap { $0.collectionListType == .folder ? $0.localIdentifier : nil }
        return PhotosAlbumContent(title: album.localizedTitle ?? "Album", folderID: folderID, assetIDs: Self.memberIDs(of: album))
    }

    public func deleteAlbum(id: String) async throws {
        let album = try Self.album(id, allowing: .delete)
        try await Self.perform {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        }
        Self.logger.notice("Deleted album \(id, privacy: .public)")
    }

    public func deleteFolder(id: String) async throws {
        let folder = try Self.folder(id, allowing: .delete)
        // Photos deletes a folder with everything in it: only an empty one goes.
        guard PHCollection.fetchCollections(in: folder, options: nil).count == 0 else { throw PhotosAlbumError.folderNotEmpty }
        try await Self.perform {
            PHCollectionListChangeRequest.deleteCollectionLists([folder] as NSArray)
        }
        Self.logger.notice("Deleted album folder \(id, privacy: .public)")
    }

    public func add(_ assetIDs: [String], toAlbum id: String) async throws -> [String] {
        let album = try Self.album(id, allowing: .addContent)
        let members = Set(Self.memberIDs(of: album))
        let added = Self.assets(assetIDs.filter { !members.contains($0) })
        guard !added.isEmpty else { return [] }
        try await Self.perform {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(added as NSArray)
        }
        Self.logger.notice("Added \(added.count) photos to album \(id, privacy: .public)")
        return added.map(\.localIdentifier)
    }

    public func remove(_ assetIDs: [String], fromAlbum id: String) async throws -> [String] {
        let album = try Self.album(id, allowing: .removeContent)
        let members = Set(Self.memberIDs(of: album))
        let removed = Self.assets(assetIDs.filter { members.contains($0) })
        guard !removed.isEmpty else { return [] }
        try await Self.perform {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(removed as NSArray)
        }
        Self.logger.notice("Removed \(removed.count) photos from album \(id, privacy: .public)")
        return removed.map(\.localIdentifier)
    }

    // MARK: - Private

    /// Runs a change block (on PhotoKit's own queue) and reports its failure as an album error.
    private static func perform(_ changes: @escaping @Sendable () -> Void) async throws {
        do {
            try await PHPhotoLibrary.shared().performChanges(changes)
        } catch {
            logger.error("Album change failed: \(error.localizedDescription, privacy: .public)")
            throw PhotosAlbumError.changeFailed(error.localizedDescription)
        }
    }

    /// The album behind an identifier, checked for the operation about to be asked of it: a change
    /// request for an album that refuses it is nil, and the change would silently do nothing.
    private static func album(_ id: String, allowing operation: PHCollectionEditOperation? = nil) throws -> PHAssetCollection {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotosAlbumError.albumUnavailable
        }
        if let operation, !album.canPerform(operation) {
            throw PhotosAlbumError.notAllowed(album.localizedTitle ?? "Album")
        }
        return album
    }

    private static func folder(_ id: String, allowing operation: PHCollectionEditOperation) throws -> PHCollectionList {
        guard let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotosAlbumError.folderUnavailable
        }
        guard folder.canPerform(operation) else {
            throw PhotosAlbumError.notAllowed(folder.localizedTitle ?? "Folder")
        }
        return folder
    }

    /// The assets behind identifiers, in the order given; a fetch by identifier promises no order.
    private static func assets(_ ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        return ids.compactMap { byID.removeValue(forKey: $0) }
    }

    /// The photos of an album in the album's own order.
    private static func memberIDs(of album: PHAssetCollection) -> [String] {
        var ids: [String] = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }
}
