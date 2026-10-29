import CoreGraphics
import Foundation
import Observation

/// A collection of photos Qaama can browse: the Apple Photos library or a folder on disk.
///
/// Sources are observable main-actor objects so views can show their assets directly.
public protocol LibrarySource: AnyObject, Observable {
    /// Name shown in the sidebar and as the window title.
    var displayName: String { get }
    /// Photos of this source, newest first. Random access only: large sources compute rows on demand.
    var assets: AssetCollection { get }
    /// One photo by identifier, without scanning the collection.
    func asset(id: LibraryAsset.ID) -> LibraryAsset?
    /// Duration of the last listing, for performance tracking.
    var lastLoadDuration: Duration? { get }
    /// What this source can store about a photo.
    var capabilities: Set<LibraryCapability> { get }

    /// Lists the photos. Calling it again once loaded is a no-op.
    func load() async
    /// Thumbnail sized for display, in pixels (account for the screen's scale factor).
    func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) async -> CGImage?
    /// Full-resolution image, oriented for display.
    func fullSizeImage(for asset: LibraryAsset) async -> CGImage?
    /// Sets the star rating (0 to 5) of a photo.
    func setRating(_ rating: Int, for asset: LibraryAsset) async throws
    func setFlag(_ flag: ItemFlag, for asset: LibraryAsset) async throws
    func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws
    /// Keywords of a photo, fetched on demand when the listing doesn't carry them.
    func keywords(for asset: LibraryAsset) async -> [String]

    /// Original pixels and previously saved recipe, to open the photo in the editor.
    func editingInput(for asset: LibraryAsset) async throws -> EditingInput
    /// Stores an edit non-destructively. Passing a recipe equal to the identity reverts the photo.
    func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws
    /// Called when the editor closes, so the source can release what it held for the edit.
    func endEditing(_ asset: LibraryAsset)
    /// Hint that the asset is on screen, so pending background work (metadata) serves it first.
    func prioritize(_ asset: LibraryAsset)
}

public extension LibrarySource {
    func endEditing(_: LibraryAsset) {}
    func prioritize(_: LibraryAsset) {}
    func setFlag(_: ItemFlag, for _: LibraryAsset) async throws {
        throw LibrarySourceError.unsupported(.flag)
    }

    func setKeywords(_: [String], for _: LibraryAsset) async throws {
        throw LibrarySourceError.unsupported(.keywords)
    }

    func keywords(for asset: LibraryAsset) async -> [String] {
        asset.keywords
    }
}

/// Decisions a source can persist about a photo.
public nonisolated enum LibraryCapability: Sendable, Hashable {
    case rating
    case flag
    case keywords
}

/// Errors shared by the library sources.
public nonisolated enum LibrarySourceError: Error, LocalizedError, Sendable {
    case unsupported(LibraryCapability)
    case folderUnreadable(URL)
    case assetUnavailable
    case editingFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(capability):
            switch capability {
            case .rating: "This library doesn't store ratings."
            case .flag: "This library doesn't store flags."
            case .keywords: "This library doesn't store keywords."
            }
        case let .folderUnreadable(url):
            "The folder “\(url.lastPathComponent)” can't be read."
        case .assetUnavailable:
            "This photo is no longer available."
        case let .editingFailed(reason):
            "The edit couldn't be saved: \(reason)"
        }
    }
}
