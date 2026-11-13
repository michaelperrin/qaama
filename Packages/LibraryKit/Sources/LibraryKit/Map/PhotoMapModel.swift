import CoreGraphics
import Foundation
import Observation
import OSLog

/// The map of a library: reads where the photos of a source's listing were taken, and answers with
/// the groups to show for the part of the world on screen.
///
/// Free of MapKit so it stays portable and testable: the view tells it the region shown and how wide
/// the whole world would be at that zoom, in points, and draws `clusters` with their `cover(of:)`.
///
/// Zooming replaces every group at once. The groups on screen stay until the thumbnails of the new
/// ones are loaded, so the map never blinks empty in between; past `patience` the new groups show
/// anyway and their thumbnails fill in as they come.
@Observable
public final class PhotoMapModel {
    /// What the photos on a map depend on: a load for the same content is a no-op.
    public nonisolated struct Content: Hashable, Sendable {
        var query: LibraryQuery
        var version: Int

        @MainActor public init(_ source: any LibrarySource) {
            // Neither the order of the grid nor a group picked on the map changes what the map shows.
            var listing = source.query
            listing.onlyAssetIDs = nil
            listing.sort = LibraryQuery.default.sort
            listing.ascending = LibraryQuery.default.ascending
            query = listing
            version = source.placesVersion
        }
    }

    /// The groups to draw; empty until photos are loaded and a region is shown. They follow the
    /// region shown as soon as their thumbnails are loaded.
    public private(set) var clusters: [PhotoCluster] = []
    /// The thumbnails loaded so far, by photo: those of `clusters`, of the groups about to replace
    /// them, and of groups shown lately, which zooming back finds at once.
    private var covers: [LibraryAsset.ID: CGImage] = [:]
    /// Pixels to ask the source for a thumbnail, set by the view from its marker size and screen.
    @ObservationIgnored public var coverPixelSize = CGSize(width: 128, height: 128)
    /// How many photos of the listing have a position; nil until they are read.
    public private(set) var locatedCount: Int?
    /// The smallest region holding them all, to frame the map the first time.
    public private(set) var extent: GeoRegion?
    /// The region last shown and whether the view already framed the photos once, kept here for the
    /// view to come back to the same place after a detour by the grid. Written on every frame of a
    /// gesture, hence not observed.
    @ObservationIgnored public var lastRegion: GeoRegion?
    @ObservationIgnored public var hasFramedPhotos = false

    @ObservationIgnored private var index = PhotoMapIndex()
    @ObservationIgnored private var loaded: Content?
    @ObservationIgnored private var viewport: (region: GeoRegion, worldWidth: Double, spacing: Double)?
    /// The groups of the region shown, which `clusters` catches up with.
    @ObservationIgnored private var wanted: [PhotoCluster] = []
    /// Where thumbnails come from: the source last loaded, unless a test stands in for it.
    @ObservationIgnored private var coverLoader: ((LibraryAsset.ID) async -> CGImage?)?
    @ObservationIgnored private let usesOwnLoader: Bool
    /// Thumbnails being loaded, and those the source had nothing for: neither is asked again.
    @ObservationIgnored private var loadingCovers: Set<LibraryAsset.ID> = []
    @ObservationIgnored private var missingCovers: Set<LibraryAsset.ID> = []
    /// Runs while `clusters` waits for thumbnails: shows the wanted groups when `patience` is over.
    @ObservationIgnored private var deadline: Task<Void, Never>?
    /// How long the groups on screen may lag behind the map for the sake of thumbnails. Long enough
    /// for thumbnails Photos has on disk (a few ms each), short enough not to feel stuck when one
    /// has to come from iCloud.
    private let patience: Duration
    /// Beyond this many thumbnails, those of groups no longer shown are dropped (64 KB each at 128 pixels).
    private static let coverLimit = 400
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotoMapModel")

    public init(patience: Duration = .milliseconds(300)) {
        self.patience = patience
        usesOwnLoader = false
    }

    /// For tests: thumbnails from this closure instead of the source's.
    init(patience: Duration, coverLoader: @escaping (LibraryAsset.ID) async -> CGImage?) {
        self.patience = patience
        self.coverLoader = coverLoader
        usesOwnLoader = true
    }

    isolated deinit {
        deadline?.cancel()
    }

    /// The thumbnail to draw for a group, or nil while it loads.
    public func cover(of cluster: PhotoCluster) -> CGImage? {
        covers[cluster.coverID]
    }

    /// Reads the positions of the source's listing and groups them again for the region shown. The
    /// groups in place stay until the new ones are ready. Cancelling the task drops its result.
    public func load(from source: any LibrarySource) async {
        let content = Content(source)
        if !usesOwnLoader {
            coverLoader = { [weak self, weak source] id in
                guard let self, let source, let asset = source.asset(id: id) else { return nil }
                return await source.thumbnail(for: asset, pixelSize: coverPixelSize)
            }
        }
        guard content != loaded else { return }
        let isReload = loaded != nil
        let clock = ContinuousClock()
        let start = clock.now
        let assets = await source.locatedAssets()
        let read = clock.now
        let index = await Task.detached(priority: .userInitiated) { PhotoMapIndex(assets) }.value
        guard !Task.isCancelled else { return }
        self.index = index
        loaded = content
        locatedCount = index.count
        extent = index.extent
        regroup()
        if isReload {
            refreshCovers()
        }
        logger.notice("Map of \(index.count) photos: positions in \((read - start).formatted(.units(allowed: [.milliseconds])), privacy: .public), index in \((clock.now - read).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// The map moved or zoomed: `region` is what it shows (with a margin, so thumbnails don't pop in at
    /// its edges), `worldWidth` how many points the whole world would take at this zoom, `spacing` the
    /// least distance wanted between two thumbnails. Called for every frame of a gesture: a pass over
    /// the photos (2 ms for 74,000 in Debug), and `clusters` only changes when the groups do.
    public func show(region: GeoRegion, worldWidth: Double, spacing: Double) {
        viewport = (region, worldWidth, spacing)
        regroup()
    }

    /// The photos of one of `clusters`; empty for a group of an earlier load.
    public func assetIDs(in cluster: PhotoCluster) -> [LibraryAsset.ID] {
        index.assetIDs(in: cluster)
    }

    private func regroup() {
        guard let viewport else { return }
        let level = PhotoMapIndex.level(worldWidth: viewport.worldWidth, spacing: viewport.spacing)
        let fresh = index.clusters(level: level, in: viewport.region)
        guard fresh != wanted else { return }
        wanted = fresh
        for cluster in fresh where covers[cluster.coverID] == nil {
            loadCover(cluster.coverID)
        }
        settle()
    }

    /// Shows the wanted groups once their thumbnails are there, or starts counting down to showing
    /// them without. The countdown starts when the groups on screen first fall behind and isn't
    /// pushed back by later moves: during a long zoom the map is never more than `patience` late.
    private func settle() {
        guard wanted != clusters else {
            deadline?.cancel()
            deadline = nil
            return
        }
        if coverLoader == nil || wanted.allSatisfy({ covers[$0.coverID] != nil || missingCovers.contains($0.coverID) }) {
            showWanted()
        } else if deadline == nil {
            deadline = Task { [weak self, patience] in
                try? await Task.sleep(for: patience)
                guard !Task.isCancelled else { return }
                self?.showWanted()
            }
        }
    }

    private func showWanted() {
        deadline?.cancel()
        deadline = nil
        // Assigning equal groups would still redraw every thumbnail of the map.
        if wanted != clusters {
            clusters = wanted
        }
        if covers.count > Self.coverLimit {
            let shown = Set(clusters.map(\.coverID))
            covers = covers.filter { shown.contains($0.key) }
        }
    }

    private func loadCover(_ id: LibraryAsset.ID, replacing: Bool = false) {
        guard let coverLoader, !loadingCovers.contains(id), replacing || !missingCovers.contains(id) else { return }
        loadingCovers.insert(id)
        Task { [weak self] in
            let image = await coverLoader(id)
            guard let self else { return }
            loadingCovers.remove(id)
            if let image {
                covers[id] = image
                missingCovers.remove(id)
            } else if covers[id] == nil {
                missingCovers.insert(id)
            }
            settle()
        }
    }

    /// The photos changed: one of those shown may have been edited. Their thumbnails are asked again
    /// and replaced as they come, without blanking the ones in place.
    private func refreshCovers() {
        missingCovers = []
        for cluster in clusters {
            loadCover(cluster.coverID, replacing: true)
        }
    }

    /// Waits until the groups shown are the wanted ones, thumbnails included or given up on; for tests.
    func waitUntilSettled() async {
        while wanted != clusters || !loadingCovers.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
