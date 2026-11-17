import Foundation
import Observation

/// Changes the albums of the Photos library: new albums and folders, deleted albums, photos added
/// to or removed from an album. Every change is one undoable step.
///
/// Changes run one after the other, undos and redos included (`UndoableSteps`). An album or folder
/// created again by an undo gets a new identifier from Photos; the editor remembers which one
/// replaced which, so earlier steps still find it.
@Observable
public final class PhotosAlbumEditor {
    /// The album photos were last added to, offered as a shortcut ("Add to <album>"); kept across launches.
    public private(set) var lastAlbumID: String? {
        didSet { defaults.set(lastAlbumID, forKey: Self.lastAlbumKey) }
    }

    private let library: any PhotosAlbumLibrary
    /// Listed again after each change to albums or folders, so callers can select what was just created.
    private let list: PhotosAlbumList?
    private let defaults: UserDefaults
    /// Identifiers of deleted albums and folders, to the ones that replaced them when an undo created them again.
    @ObservationIgnored private var replacements: [String: String] = [:]
    /// The changes in flight and their undos. The editor lives as long as the app: a safe target.
    @ObservationIgnored private lazy var steps = UndoableSteps<Step>(category: "PhotosAlbumEditor") { [weak self] step in
        try await self?.perform(step)
    }

    private static let lastAlbumKey = "PhotosLastAlbumID"

    public init(library: any PhotosAlbumLibrary, list: PhotosAlbumList? = nil, defaults: UserDefaults = .standard) {
        self.library = library
        self.list = list
        self.defaults = defaults
        lastAlbumID = defaults.string(forKey: Self.lastAlbumKey)
    }

    // MARK: - Changes

    /// Creates an album in a folder (nil: at the top level), holding the given photos, and returns
    /// its identifier. An album created with photos becomes the last album.
    @discardableResult
    public func createAlbum(titled title: String, inFolder folderID: String? = nil, containing assetIDs: [String] = [],
                            undoManager: UndoManager?) async throws -> String
    {
        let content = PhotosAlbumContent(title: title, folderID: folderID, assetIDs: assetIDs)
        let inverse = try await steps.run(.createAlbum(content, replacing: nil))
        guard case let .deleteAlbum(id) = inverse else { throw PhotosAlbumError.changeFailed("no album was created") }
        if !assetIDs.isEmpty {
            lastAlbumID = id
        }
        steps.register(inverse, named: "New Album", with: undoManager)
        return id
    }

    /// Creates a folder of albums in another folder (nil: at the top level) and returns its identifier.
    @discardableResult
    public func createFolder(titled title: String, inFolder parentID: String? = nil, undoManager: UndoManager?) async throws -> String {
        let inverse = try await steps.run(.createFolder(title: title, parentID: parentID, replacing: nil))
        guard case let .deleteFolder(id, _, _) = inverse else { throw PhotosAlbumError.changeFailed("no folder was created") }
        steps.register(inverse, named: "New Folder", with: undoManager)
        return id
    }

    /// Deletes an album; its photos stay in the library. Undoing creates it again with the same
    /// title, in the same folder, with the same photos.
    public func deleteAlbum(id: String, undoManager: UndoManager?) async throws {
        let inverse = try await steps.run(.deleteAlbum(id: id))
        steps.register(inverse, named: "Delete Album", with: undoManager)
    }

    /// Adds photos to an album, which becomes the last album. Returns the number of photos added:
    /// those already in the album are left alone, and an undo doesn't take them out.
    @discardableResult
    public func add(_ assetIDs: [String], toAlbum id: String, undoManager: UndoManager?) async throws -> Int {
        let inverse = try await steps.run(.add(assetIDs, albumID: id))
        lastAlbumID = current(id)
        steps.register(inverse, named: "Add to Album", with: undoManager)
        if case let .remove(added, _) = inverse {
            return added.count
        }
        return 0
    }

    /// Removes photos from an album; they stay in the library. Returns the number of photos removed.
    /// Undoing puts them back at the end of the album.
    @discardableResult
    public func remove(_ assetIDs: [String], fromAlbum id: String, undoManager: UndoManager?) async throws -> Int {
        let inverse = try await steps.run(.remove(assetIDs, albumID: id))
        steps.register(inverse, named: "Remove from Album", with: undoManager)
        if case let .add(removed, _) = inverse {
            return removed.count
        }
        return 0
    }

    /// Waits for the changes in flight, undos and redos included; for tests.
    func waitUntilIdle() async {
        await steps.waitUntilIdle()
    }

    // MARK: - Steps

    /// One change to the albums, described well enough to be made again after an undo.
    private nonisolated enum Step: Sendable {
        /// `replacing` is the identifier the album had before it was deleted.
        case createAlbum(PhotosAlbumContent, replacing: String?)
        case deleteAlbum(id: String)
        case createFolder(title: String, parentID: String?, replacing: String?)
        /// Title and parent are what creating the folder again takes.
        case deleteFolder(id: String, title: String, parentID: String?)
        case add([String], albumID: String)
        case remove([String], albumID: String)
    }

    /// Makes a change and returns the step that reverts it; nil when nothing changed.
    private func perform(_ step: Step) async throws -> Step? {
        switch step {
        case let .createAlbum(content, replacing):
            var content = content
            content.folderID = content.folderID.map(current)
            let id = try await library.createAlbum(content)
            replace(replacing, with: id)
            list?.reload()
            return .deleteAlbum(id: id)
        case let .deleteAlbum(id):
            let id = current(id)
            let content = try await library.albumContent(id: id)
            try await library.deleteAlbum(id: id)
            list?.reload()
            return .createAlbum(content, replacing: id)
        case let .createFolder(title, parentID, replacing):
            let parentID = parentID.map(current)
            let id = try await library.createFolder(titled: title, inFolder: parentID)
            replace(replacing, with: id)
            list?.reload()
            return .deleteFolder(id: id, title: title, parentID: parentID)
        case let .deleteFolder(id, title, parentID):
            let id = current(id)
            try await library.deleteFolder(id: id)
            list?.reload()
            return .createFolder(title: title, parentID: parentID, replacing: id)
        case let .add(assetIDs, albumID):
            let added = try await library.add(assetIDs, toAlbum: current(albumID))
            return added.isEmpty ? nil : .remove(added, albumID: albumID)
        case let .remove(assetIDs, albumID):
            let removed = try await library.remove(assetIDs, fromAlbum: current(albumID))
            return removed.isEmpty ? nil : .add(removed, albumID: albumID)
        }
    }

    /// The identifier an album or folder has now, after the undos that created it again.
    private func current(_ id: String) -> String {
        var id = id
        while let next = replacements[id] {
            id = next
        }
        return id
    }

    private func replace(_ old: String?, with new: String) {
        guard let old, old != new else { return }
        replacements[old] = new
        if lastAlbumID == old {
            lastAlbumID = new
        }
    }
}
