import Foundation
@testable import LibraryKit

/// Albums and folders in memory, standing in for PhotoKit. Like Photos, it never gives an identifier
/// twice: an album created again is a new one.
actor FakeAlbumLibrary: PhotosAlbumLibrary {
    private(set) var albums: [String: PhotosAlbumContent] = [:]
    /// Folders by identifier, with their parent's.
    private(set) var folders: [String: (title: String, parentID: String?)] = [:]
    private var counter = 0
    /// Every change made, in order, to check that undos and redos don't overtake each other.
    private(set) var journal: [String] = []

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)"
    }

    /// The only album with this title; nil when there is none or several.
    func albumID(titled title: String) -> String? {
        let matches = albums.filter { $0.value.title == title }
        return matches.count == 1 ? matches.first?.key : nil
    }

    func assetIDs(inAlbum id: String) -> [String]? {
        albums[id]?.assetIDs
    }

    // MARK: - PhotosAlbumLibrary

    func createAlbum(_ content: PhotosAlbumContent) throws -> String {
        if let folderID = content.folderID, folders[folderID] == nil {
            throw PhotosAlbumError.folderUnavailable
        }
        let id = nextID("album")
        albums[id] = content
        journal.append("create \(id)")
        return id
    }

    func createFolder(titled title: String, inFolder parentID: String?) throws -> String {
        if let parentID, folders[parentID] == nil {
            throw PhotosAlbumError.folderUnavailable
        }
        let id = nextID("folder")
        folders[id] = (title, parentID)
        journal.append("create \(id)")
        return id
    }

    func albumContent(id: String) throws -> PhotosAlbumContent {
        guard let content = albums[id] else { throw PhotosAlbumError.albumUnavailable }
        return content
    }

    func deleteAlbum(id: String) throws {
        guard albums.removeValue(forKey: id) != nil else { throw PhotosAlbumError.albumUnavailable }
        journal.append("delete \(id)")
    }

    func deleteFolder(id: String) throws {
        guard folders[id] != nil else { throw PhotosAlbumError.folderUnavailable }
        let isEmpty = !albums.values.contains { $0.folderID == id } && !folders.values.contains { $0.parentID == id }
        guard isEmpty else { throw PhotosAlbumError.folderNotEmpty }
        folders[id] = nil
        journal.append("delete \(id)")
    }

    func add(_ assetIDs: [String], toAlbum id: String) throws -> [String] {
        guard var content = albums[id] else { throw PhotosAlbumError.albumUnavailable }
        let added = assetIDs.filter { !content.assetIDs.contains($0) }
        content.assetIDs += added
        albums[id] = content
        journal.append("add \(added.count) to \(id)")
        return added
    }

    func remove(_ assetIDs: [String], fromAlbum id: String) throws -> [String] {
        guard var content = albums[id] else { throw PhotosAlbumError.albumUnavailable }
        let removed = assetIDs.filter { content.assetIDs.contains($0) }
        content.assetIDs.removeAll { removed.contains($0) }
        albums[id] = content
        journal.append("remove \(removed.count) from \(id)")
        return removed
    }
}
