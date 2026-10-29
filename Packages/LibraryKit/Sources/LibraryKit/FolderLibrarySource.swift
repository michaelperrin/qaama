import CoreGraphics
import Foundation
import Observation
import OSLog

/// "Folder on disk" source: lists the image files below a folder chosen by the user.
///
/// Holds the security-scoped access to the folder for as long as it lives.
@Observable
public final class FolderLibrarySource: LibrarySource, Identifiable {
    public let id: UUID
    public let folderURL: URL
    public private(set) var assets: [LibraryAsset] = []
    public private(set) var lastLoadDuration: Duration?
    public private(set) var isLoaded = false
    /// Message to show when the folder could not be listed.
    public private(set) var loadError: String?

    public var displayName: String {
        folderURL.lastPathComponent
    }

    public var canRate: Bool {
        false
    }

    private let hasSecurityScope: Bool
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FolderLibrarySource")

    public init(folderURL: URL, id: UUID = UUID()) {
        self.id = id
        self.folderURL = folderURL
        hasSecurityScope = folderURL.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope {
            folderURL.stopAccessingSecurityScopedResource()
        }
    }

    public func load() async {
        guard !isLoaded else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let folder = folderURL
        do {
            assets = try await Task.detached(priority: .userInitiated) { try FolderScanner.scan(folder) }.value
            loadError = nil
        } catch {
            assets = []
            loadError = error.localizedDescription
        }
        isLoaded = true
        lastLoadDuration = clock.now - start
        logger.notice("Listed \(self.assets.count) files in \(self.folderURL.lastPathComponent, privacy: .public) in \(self.lastLoadDuration!.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// Forgets the listing so the next `load()` scans the folder again.
    public func invalidate() {
        isLoaded = false
    }

    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize) async -> CGImage? {
        await FileImageLoader.thumbnail(at: URL(filePath: asset.id), pixelSize: pixelSize)
    }

    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        let url = URL(filePath: asset.id)
        return await Task.detached(priority: .userInitiated) { FileImageLoader.fullSizeImage(at: url) }.value
    }

    /// Ratings for files will live in a sidecar; not part of this building block yet.
    public func setRating(_: Int, for _: LibraryAsset) async throws {
        throw LibrarySourceError.ratingUnsupported
    }
}
