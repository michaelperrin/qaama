import Foundation
import Observation
import OSLog

/// The albums the photos shown in an Info panel are in: those of the photo, or with several photos
/// those every one of them is in, as the panel does for keywords.
///
/// Identifiers only: the panel names them from the album hierarchy, and leaves out those the
/// hierarchy doesn't list (shared and synced albums).
@Observable
public final class AssetAlbumsModel {
    /// The albums every photo shown is in; nil until they are read.
    public private(set) var albumIDs: Set<PhotosAlbum.ID>?

    /// The photos last asked for.
    private var assetIDs: [LibraryAsset.ID] = []
    /// Bumped by every `show`: an answer that comes back for an older call is dropped.
    private var generation = 0
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "AssetAlbumsModel")

    public init() {}

    /// Reads the albums of these photos, one request per photo. Calling it again, or cancelling the
    /// calling task, abandons the reading in flight. Called again with the same photos (one was
    /// added to an album), it keeps what is shown until the new answer is there.
    public func show(_ assets: [LibraryAsset], in source: any LibrarySource) async {
        generation += 1
        let current = generation
        let ids = assets.map(\.id)
        if ids != assetIDs {
            albumIDs = nil
        }
        assetIDs = ids
        guard !assets.isEmpty else { return }

        let clock = ContinuousClock()
        let start = clock.now
        var shared: Set<PhotosAlbum.ID>?
        for asset in assets {
            let own = await Set(source.albumIDs(containing: asset))
            guard current == generation, !Task.isCancelled else { return }
            shared = shared?.intersection(own) ?? own
        }
        albumIDs = shared
        Self.logger.notice("Read the albums of \(assets.count) photos in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// True once the model holds the albums of exactly these photos. Between a change of selection
    /// and the start of its reading, it still holds the previous one's.
    public func isShowing(_ assets: [LibraryAsset]) -> Bool {
        albumIDs != nil && assetIDs == assets.map(\.id)
    }
}
