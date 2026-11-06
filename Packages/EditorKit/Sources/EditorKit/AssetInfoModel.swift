import CoreGraphics
import CoreImage
import Foundation
import LibraryKit
import Observation
import OSLog
import RenderEngine

/// What the library's Info panel shows about the photos selected in the grid, without opening them
/// in the editor: the decisions made about them (rating, flag, keywords), which it also changes,
/// what the source says about the files, and for a single photo a histogram.
///
/// With several photos, each line holds what they share. Reading that takes one request per photo
/// (15 to 120 ms each in the Photos library, measured), so the panel compares up to
/// `selectionLimit` photos; the view counts larger selections without handing them over.
///
/// The histogram is computed on the photo's thumbnail, so it describes what the grid shows: the
/// saved edit when there is one, the camera's own preview for an untouched RAW. The editor's
/// histogram comes from its own render and can differ slightly.
@Observable
public final class AssetInfoModel {
    /// The largest selection the panel compares.
    public nonisolated static let selectionLimit = 50

    /// The photos last asked for; empty while nothing is shown.
    public private(set) var assets: [LibraryAsset] = []
    /// What the source says about the photo, when there is exactly one.
    public private(set) var details: AssetDetails?
    /// What several photos share; nil until they have all been read.
    public private(set) var summary: InfoSummary?
    /// True while several photos are being read for the first time.
    public private(set) var isSummarizing = false
    /// Stays on the previous photo's until the new one is computed, rather than blinking empty.
    public private(set) var histogram: Histogram?
    /// The keywords of the photo, or those every selected photo has.
    public private(set) var keywords: [String] = []
    /// False until the keywords of the photos shown have been read: there is nothing to edit before.
    public private(set) var hasLoadedKeywords = false
    /// True while the source downloads the photo's original to read its header.
    public private(set) var isDownloadingOriginal = false
    /// True when the last download brought nothing back (no connection, typically).
    public private(set) var originalDownloadFailed = false
    /// What went wrong the last time a decision was written, to show as is.
    public private(set) var errorMessage: String?

    /// Long edge of the thumbnail the histogram is computed on, the size `HistogramComputer` samples at.
    static let histogramPixelSize = CGSize(width: 512, height: 512)

    /// Bumped by every `show`: an answer that comes back for an older call is dropped.
    private var generation = 0
    @ObservationIgnored private var download: Task<Void, Never>?
    /// Every photo's own keywords, to tell which are shared and to edit them photo by photo.
    private var keywordsByID: [LibraryAsset.ID: [String]] = [:]
    /// Details already read for the selection in place: a rating or a keyword changes the photos
    /// handed in, not what their files say, and must not cost a new read of each.
    @ObservationIgnored private var detailsCache: [DetailsKey: AssetDetails] = [:]

    private struct DetailsKey: Hashable {
        let id: LibraryAsset.ID
        /// A corrected capture date is part of the details.
        let creationDate: Date?
    }

    public init() {}

    /// The photo shown, when there is exactly one.
    public var asset: LibraryAsset? {
        assets.count == 1 ? assets[0] : nil
    }

    // MARK: - Showing

    /// Shows one photo, or nothing when it is nil.
    public func show(_ asset: LibraryAsset?, in source: any LibrarySource) async {
        await show(asset.map { [$0] } ?? [], in: source)
    }

    /// Shows the selected photos. What the listing knows is there at once, the rest follows as the
    /// source answers. Calling it again, or cancelling the calling task, abandons the load in
    /// flight: the selection moved on. Called again with the same photos (one was rated, edited),
    /// it keeps what is shown while it reads them again.
    public func show(_ assets: [LibraryAsset], in source: any LibrarySource) async {
        generation += 1
        let current = generation
        if Set(assets.map(\.id)) != Set(self.assets.map(\.id)) {
            abandonDownload()
            details = assets.count == 1 ? AssetDetails(assets[0]) : nil
            summary = nil
            keywords = []
            keywordsByID = [:]
            hasLoadedKeywords = false
            detailsCache = [:]
            errorMessage = nil
            if assets.count != 1 {
                histogram = nil
            }
        }
        self.assets = assets
        guard !assets.isEmpty else { return }

        var loadedKeywords: [LibraryAsset.ID: [String]] = [:]
        for asset in assets {
            loadedKeywords[asset.id] = await source.keywords(for: asset)
            guard current == generation, !Task.isCancelled else { return }
        }
        keywordsByID = loadedKeywords
        keywords = Self.shared(assets.map { loadedKeywords[$0.id] ?? [] })
        hasLoadedKeywords = true

        isSummarizing = assets.count > 1 && summary == nil
        let clock = ContinuousClock()
        let start = clock.now
        var read = 0
        var all: [AssetDetails] = []
        for asset in assets {
            let key = DetailsKey(id: asset.id, creationDate: asset.creationDate)
            if let cached = detailsCache[key] {
                all.append(cached)
                continue
            }
            let loaded = await source.details(for: asset, allowingDownload: false)
            guard current == generation, !Task.isCancelled else { return }
            detailsCache[key] = loaded
            all.append(loaded)
            read += 1
        }
        isSummarizing = false
        guard assets.count == 1 else {
            summary = InfoSummary(all)
            if read > 1 {
                Self.logger.notice("Compared \(read) photos in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            }
            return
        }
        details = all[0]

        let thumbnail = await source.thumbnail(for: assets[0], pixelSize: Self.histogramPixelSize)
        guard current == generation, !Task.isCancelled else { return }
        guard let thumbnail else {
            histogram = nil
            return
        }
        let computed = await Task.detached(priority: .utility) { HistogramComputer.compute(CIImage(cgImage: thumbnail)) }.value
        guard current == generation, !Task.isCancelled else { return }
        histogram = computed
    }

    /// The details to show for `asset`: the loaded ones once they are its own, what the listing knows
    /// until then (the frame between a click and the start of the load).
    public func details(for asset: LibraryAsset) -> AssetDetails {
        if self.asset?.id == asset.id, let details {
            return details
        }
        return AssetDetails(asset)
    }

    // MARK: - Original in iCloud

    /// Downloads the original of the photo shown, at the user's request, to complete details that
    /// came back with `isOriginalInCloud`. Moving to another photo abandons the download.
    public func downloadOriginal(in source: any LibrarySource) {
        guard let asset, download == nil else { return }
        isDownloadingOriginal = true
        originalDownloadFailed = false
        download = Task { [weak self] in
            let loaded = await source.details(for: asset, allowingDownload: true)
            guard let self, !Task.isCancelled, self.asset?.id == asset.id else { return }
            details = loaded
            detailsCache[DetailsKey(id: asset.id, creationDate: asset.creationDate)] = loaded
            originalDownloadFailed = loaded.isOriginalInCloud
            isDownloadingOriginal = false
            download = nil
        }
    }

    /// Waits for the download in flight; for tests.
    func waitForDownload() async {
        await download?.value
    }

    private func abandonDownload() {
        download?.cancel()
        download = nil
        isDownloadingOriginal = false
        originalDownloadFailed = false
    }

    // MARK: - Decisions

    /// True once the model shows exactly these photos. Between a change of selection and the start
    /// of its load, the model still holds the previous one.
    public func isShowing(_ assets: [LibraryAsset]) -> Bool {
        self.assets.map(\.id) == assets.map(\.id)
    }

    /// The rating every photo shown has; nil when they differ, or nothing is shown.
    public var rating: Int? {
        Self.shared(assets.map(\.rating))
    }

    /// The flag every photo shown has; nil when they differ, or nothing is shown.
    public var flag: ItemFlag? {
        Self.shared(assets.map(\.flag))
    }

    /// The rating these photos share: the model's own answer once it shows them (a decision made in
    /// the panel is there at once), what the photos themselves say until then.
    public func rating(of assets: [LibraryAsset]) -> Int? {
        isShowing(assets) ? rating : Self.shared(assets.map(\.rating))
    }

    public func flag(of assets: [LibraryAsset]) -> ItemFlag? {
        isShowing(assets) ? flag : Self.shared(assets.map(\.flag))
    }

    /// Gives every photo shown this rating, as one undoable step.
    public func setRating(_ rating: Int, in source: any LibrarySource, undoManager: UndoManager?) async {
        let changes = assets.filter { $0.rating != rating }.map { ($0, LibraryDecision.rating(rating)) }
        // The panel answers at once; the source's own update follows, sometimes a moment later (Photos).
        for index in assets.indices {
            assets[index].rating = rating
        }
        await write(changes, in: source, undoManager: undoManager)
    }

    /// Gives every photo shown this flag, as one undoable step.
    public func setFlag(_ flag: ItemFlag, in source: any LibrarySource, undoManager: UndoManager?) async {
        let changes = assets.filter { $0.flag != flag }.map { ($0, LibraryDecision.flag(flag)) }
        for index in assets.indices {
            assets[index].flag = flag
        }
        await write(changes, in: source, undoManager: undoManager)
    }

    /// Takes the keywords as edited in the panel. With several photos the panel shows the shared
    /// ones: a keyword added there is added to every photo, one removed is removed from every photo,
    /// and the keywords only some photos have stay where they are.
    public func setKeywords(_ edited: [String], in source: any LibrarySource, undoManager: UndoManager?) async {
        guard hasLoadedKeywords else { return }
        let added = edited.filter { !keywords.contains($0) }
        let removed = Set(keywords.filter { !edited.contains($0) })
        guard !added.isEmpty || !removed.isEmpty else { return }
        var changes: [(LibraryAsset, LibraryDecision)] = []
        for asset in assets {
            let own = keywordsByID[asset.id] ?? []
            let kept = own.filter { !removed.contains($0) }
            let updated = kept + added.filter { !kept.contains($0) }
            if updated != own {
                keywordsByID[asset.id] = updated
                changes.append((asset, .keywords(updated)))
            }
        }
        keywords = Self.shared(assets.map { keywordsByID[$0.id] ?? [] })
        await write(changes, in: source, undoManager: undoManager)
    }

    private func write(_ changes: [(LibraryAsset, LibraryDecision)], in source: any LibrarySource, undoManager: UndoManager?) async {
        guard !changes.isEmpty else { return }
        do {
            try await MetadataEditing.apply(changes, in: source, undoManager: undoManager)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "AssetInfoModel")

    /// The value all share; nil when they differ or there is none.
    public nonisolated static func shared<Value: Equatable>(_ values: [Value]) -> Value? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// The keywords every list has, in the order of the first.
    static func shared(_ lists: [[String]]) -> [String] {
        guard let first = lists.first else { return [] }
        return first.filter { keyword in lists.allSatisfy { $0.contains(keyword) } }
    }
}
