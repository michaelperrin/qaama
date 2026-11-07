import Foundation

/// What it takes to create an album, or to create again one that was deleted.
public nonisolated struct PhotosAlbumContent: Hashable, Sendable {
    public var title: String
    /// The folder holding the album; nil at the top level.
    public var folderID: String?
    /// The photos of the album, in the album's own order.
    public var assetIDs: [String]

    public init(title: String, folderID: String? = nil, assetIDs: [String] = []) {
        self.title = title
        self.folderID = folderID
        self.assetIDs = assetIDs
    }
}

/// The albums and folders of the photo library as `PhotosAlbumEditor` changes them: PhotoKit in the
/// app (`PhotoKitAlbumLibrary`), a fake in tests. Albums, folders and photos are named by identifier.
/// Every call may block; the editor runs them off the main actor.
public nonisolated protocol PhotosAlbumLibrary: Sendable {
    /// Creates an album and returns its identifier.
    func createAlbum(_ content: PhotosAlbumContent) async throws -> String
    /// Creates a folder of albums in `parentID` (nil: at the top level) and returns its identifier.
    func createFolder(titled title: String, inFolder parentID: String?) async throws -> String
    /// Title, folder and photos of an album: what creating it again takes.
    func albumContent(id: String) async throws -> PhotosAlbumContent
    /// Deletes an album; its photos stay in the library.
    func deleteAlbum(id: String) async throws
    /// Deletes a folder that holds nothing; throws `folderNotEmpty` otherwise.
    func deleteFolder(id: String) async throws
    /// Adds photos to an album and returns those that weren't in it yet.
    func add(_ assetIDs: [String], toAlbum id: String) async throws -> [String]
    /// Removes photos from an album and returns those that were in it.
    func remove(_ assetIDs: [String], fromAlbum id: String) async throws -> [String]
}

/// Errors of album management.
public nonisolated enum PhotosAlbumError: Error, LocalizedError, Sendable, Equatable {
    case albumUnavailable
    case folderUnavailable
    /// Photos refuses the change for this album or folder (synced or shared ones), named by its title.
    case notAllowed(String)
    case folderNotEmpty
    case changeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .albumUnavailable: "This album is no longer in the Photos library."
        case .folderUnavailable: "This folder is no longer in the Photos library."
        case let .notAllowed(title): "Photos doesn't allow this change to “\(title)”."
        case .folderNotEmpty: "The folder isn't empty."
        case let .changeFailed(reason): "Photos couldn't make the change: \(reason)"
        }
    }
}
