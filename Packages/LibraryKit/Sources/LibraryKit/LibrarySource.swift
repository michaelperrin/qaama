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
    /// Position of a photo in `assets`, or nil when the current query doesn't list it.
    func index(of id: LibraryAsset.ID) -> Int?
    /// Duration of the last listing, for performance tracking.
    var lastLoadDuration: Duration? { get }
    /// What this source can store about a photo.
    var capabilities: Set<LibraryCapability> { get }
    /// Sorting and filtering of `assets`. Setting it refreshes the collection.
    var query: LibraryQuery { get set }
    /// The parts of a query this source honors; the UI disables the others.
    var queryCapabilities: Set<QueryCapability> { get }

    /// Lists the photos. Calling it again once loaded is a no-op.
    func load() async
    /// Thumbnail for a square of `pixelSize` a side (account for the screen's scale factor), with enough
    /// pixels to fill it or to fit in it, as `fit` says.
    func thumbnail(for asset: LibraryAsset, pixelSize: CGSize, fit: ThumbnailFit) async -> CGImage?
    /// Full-resolution image, oriented for display.
    func fullSizeImage(for asset: LibraryAsset) async -> CGImage?
    /// Sets the star rating (0 to 5) of a photo.
    func setRating(_ rating: Int, for asset: LibraryAsset) async throws
    func setFlag(_ flag: ItemFlag, for asset: LibraryAsset) async throws
    func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws
    /// Keywords of a photo, fetched on demand when the listing doesn't carry them.
    func keywords(for asset: LibraryAsset) async -> [String]
    /// When the photo was taken as the source holds it now, corrections included; nil when nothing says.
    /// Read from the source's current state, not from `asset`, which may be an older snapshot.
    func captureDate(for asset: LibraryAsset) -> Date?
    /// Corrects the capture date of a photo, without touching its file. Nil removes the correction
    /// where the source keeps one apart from the file's own date (folders).
    func setCaptureDate(_ date: Date?, for asset: LibraryAsset) async throws

    /// Original pixels and previously saved recipe, to open the photo in the editor.
    func editingInput(for asset: LibraryAsset) async throws -> EditingInput
    /// Stores an edit non-destructively. Passing a recipe equal to the identity reverts the photo.
    func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws
    /// Called when the editor closes, so the source can release what it held for the edit.
    func endEditing(_ asset: LibraryAsset)
    /// Hint that the asset is on screen, so pending background work (metadata) serves it first.
    func prioritize(_ asset: LibraryAsset)
    /// What files back the asset (RAW, RAW + JPEG), fetched on demand when the listing doesn't know.
    func resourceInfo(for asset: LibraryAsset) async -> AssetResourceInfo
    /// File name and header of a photo, for the Info panel of the grid. Unless `allowingDownload` is
    /// true (the user asked for it), nothing is downloaded: a source whose original is elsewhere
    /// answers with what it knows and sets `isOriginalInCloud`.
    func details(for asset: LibraryAsset, allowingDownload: Bool) async -> AssetDetails
    /// The grid shows the row at `index`: sources may warm the thumbnails around it, as the grid will ask
    /// for them (same size and fit).
    func prefetchThumbnails(around index: Int, pixelSize: CGSize, fit: ThumbnailFit)
    /// How far a background index this source's listing relies on is, or nil when none is being built.
    var indexingProgress: IndexingProgress? { get }
    /// A sentence to show with the photos while indexing makes the current listing provisional, or nil
    /// when what is shown is final.
    var indexingNotice: String? { get }
}

/// Progress of a background indexing pass.
public nonisolated struct IndexingProgress: Hashable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// From 0 to 1; 1 when there is nothing to index.
    public var fraction: Double {
        total > 0 ? min(Double(done) / Double(total), 1) : 1
    }
}

/// Which kind of files stand behind a photo.
public nonisolated struct AssetResourceInfo: Hashable, Sendable {
    public var isRAW: Bool
    /// A JPEG shot together with the RAW: a paired file in a folder, an alternate resource in Photos.
    public var hasJPEGTwin: Bool
    /// The file name the photo was imported or shot under, extension included; exports are named after it.
    public var originalFileName: String?

    public init(isRAW: Bool, hasJPEGTwin: Bool, originalFileName: String? = nil) {
        self.isRAW = isRAW
        self.hasJPEGTwin = hasJPEGTwin
        self.originalFileName = originalFileName
    }

    public init(_ asset: LibraryAsset) {
        self.init(isRAW: asset.isRAW, hasJPEGTwin: asset.pairedAssetID != nil)
    }
}

public extension LibrarySource {
    /// A linear scan; sources that can do better override it.
    func index(of id: LibraryAsset.ID) -> Int? {
        assets.firstIndex { $0.id == id }
    }

    /// The photo `offset` places after `id` in `assets` (negative: before), for stepping through
    /// the library from the editor. Nil at either end, or when `id` is no longer listed.
    func neighbor(of id: LibraryAsset.ID, offset: Int) -> LibraryAsset.ID? {
        guard let index = index(of: id) else { return nil }
        let target = index + offset
        return assets.indices.contains(target) ? assets[target].id : nil
    }

    /// A thumbnail that fills its square, for the places that show one photo at a fixed size.
    func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) async -> CGImage? {
        await thumbnail(for: asset, pixelSize: pixelSize, fit: .fill)
    }

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

    func captureDate(for asset: LibraryAsset) -> Date? {
        asset.creationDate
    }

    func setCaptureDate(_: Date?, for _: LibraryAsset) async throws {
        throw LibrarySourceError.unsupported(.captureDate)
    }

    func resourceInfo(for asset: LibraryAsset) async -> AssetResourceInfo {
        AssetResourceInfo(asset)
    }

    func details(for asset: LibraryAsset, allowingDownload _: Bool) async -> AssetDetails {
        AssetDetails(asset)
    }

    func prefetchThumbnails(around _: Int, pixelSize _: CGSize, fit _: ThumbnailFit) {}

    var indexingProgress: IndexingProgress? {
        nil
    }

    var indexingNotice: String? {
        nil
    }
}

/// Decisions a source can persist about a photo.
public nonisolated enum LibraryCapability: Sendable, Hashable {
    case rating
    case flag
    case keywords
    /// Correcting when a photo was taken.
    case captureDate
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
            case .captureDate: "This library doesn't store corrected dates."
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
