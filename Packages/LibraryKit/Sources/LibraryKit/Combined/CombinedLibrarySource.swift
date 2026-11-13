import CoreGraphics
import Foundation
import Observation
import OSLog

/// Several sources shown on one map: every photo of the Photos library and of the folders, where it
/// was taken, whichever library holds it.
///
/// It holds no photo itself, and lists none until a group is picked on the map
/// (`LibraryQuery.onlyAssetIDs`): each member then lists its photos of the group, their listings are
/// woven by date (`ListingMerge`), and everything asked about a photo goes to the member that holds
/// it. Identifiers are the members' own, so a photo is the same photo here and in its library.
///
/// Weaving every photo of every member into one grid was tried and dropped (13/11/2026): it cost a
/// reading of the whole Photos library's dates at each opening and each change (1.3 s for 74,000
/// photos), for a grid that could only offer what every member can do.
///
/// The members must be this library's own instances: it sets their query. In the grid of a group,
/// only what every member can do is offered (a flag exists in folders, not in Photos), and only
/// the orders that weave: by capture date or by modification date.
@Observable
public final class CombinedLibrarySource: LibrarySource {
    public let displayName: String
    /// The photos of the group picked on the map; empty without one.
    public private(set) var assets: AssetCollection = .empty
    public private(set) var timeline: DateTimeline?
    /// Duration of the last weaving, reading the members' dates included.
    public private(set) var lastLoadDuration: Duration?
    /// True once the members are listed.
    public private(set) var isLoaded = false

    /// The sources shown together, asked in this order which one holds a photo: those that answer
    /// from memory come first.
    public private(set) var members: [any LibrarySource]

    public var query = LibraryQuery.default {
        didSet {
            guard query != oldValue else { return }
            applyQuery(to: members)
            scheduleWeave()
        }
    }

    /// Run before the members are loaded, and again when they change: the owner's chance to start
    /// what they rely on (the scan of the folders).
    @ObservationIgnored public var prepare: (() async -> Void)?

    /// The weaving `assets` shows, and the members' listings it was made from: a member whose listing
    /// has changed since still answers for the rows on screen until the next weaving is ready.
    @ObservationIgnored private var merge = ListingMerge()
    @ObservationIgnored private var woven: [AssetCollection] = []
    /// The member holding each photo asked about so far.
    @ObservationIgnored private var owners: [LibraryAsset.ID: Int] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var weaving: Task<Void, Never>?
    /// Number of the weaving asked last: an older one still running is dropped.
    @ObservationIgnored private var generation = 0
    /// Bumped with the members, for the map: their own versions say nothing of a member that left.
    private var membersVersion = 0
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "CombinedLibrarySource")

    public init(displayName: String, members: [any LibrarySource] = []) {
        self.displayName = displayName
        self.members = members
        applyQuery(to: members)
    }

    isolated deinit {
        weaving?.cancel()
    }

    // MARK: - Members

    /// Replaces the members (a folder was added or removed). New ones are loaded when the library
    /// already is.
    public func setMembers(_ members: [any LibrarySource]) {
        self.members = members
        owners = [:]
        membersVersion += 1
        applyQuery(to: members)
        guard isStarted else { return }
        Task { [weak self] in
            await self?.loadMembers()
            self?.scheduleWeave()
        }
    }

    public func load() async {
        guard !isStarted else { return }
        isStarted = true
        await loadMembers()
        follow()
        await weave(number: nextGeneration())
    }

    private func loadMembers() async {
        await prepare?()
        for member in members {
            await member.load()
        }
    }

    /// A member's query is this library's, but for what belongs to one source: a folder's subdirectory.
    private func applyQuery(to members: [any LibrarySource]) {
        var shared = query
        shared.folderPath = nil
        for member in members where member.query != shared {
            member.query = shared
        }
    }

    /// Weaves again whenever a member's listing changes: photos added, a filter applied, headers read.
    private func follow() {
        withObservationTracking {
            for member in members {
                _ = member.assets
            }
            _ = members.count
        } onChange: { [weak self] in
            Task { @MainActor in self?.membersChanged() }
        }
    }

    private func membersChanged() {
        scheduleWeave()
        follow()
    }

    // MARK: - Weaving

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func scheduleWeave() {
        guard isStarted else { return }
        let number = nextGeneration()
        weaving = Task { [weak self] in await self?.weave(number: number) }
    }

    /// Reads the dates of every member's listing of the group, weaves them off the main actor and
    /// publishes the result, unless a newer weaving was asked meanwhile. The listing in place stays
    /// until then. Without a group there is nothing to list, and nothing is read.
    private func weave(number: Int) async {
        guard query.onlyAssetIDs != nil else {
            if !merge.entries.isEmpty {
                merge = ListingMerge()
                woven = []
                assets = .empty
                timeline = nil
            }
            isLoaded = true
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        let members = members
        var dates: [[Date?]] = []
        for member in members {
            await dates.append(member.listingDates())
            guard number == generation else { return }
        }
        let listings = members.map(\.assets)
        // A member moved on while its dates were read: its change asked for another weaving.
        guard zip(listings, dates).allSatisfy({ $0.count == $1.count }) else {
            logger.notice("A listing changed while it was read; weaving again")
            return
        }
        let ascending = query.ascending
        let merge = await Task.detached(priority: .userInitiated) { ListingMerge(dates: dates, ascending: ascending) }.value
        // The group was closed while it was being woven.
        guard number == generation, query.onlyAssetIDs != nil else { return }

        self.merge = merge
        woven = listings
        let entries = merge.entries
        // The row closure must stay free of side effects: SwiftUI may walk the whole collection.
        assets = AssetCollection(count: entries.count) { index in
            let entry = entries[index]
            return listings[Int(entry.listing)][Int(entry.row)]
        }
        let months = query.sort == .captureDate ? merge.timeline : nil
        if months != timeline {
            timeline = months
        }
        lastLoadDuration = clock.now - start
        isLoaded = true
        logger.notice("Wove \(entries.count) photos of \(members.count) sources in \(self.lastLoadDuration!.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    // MARK: - Finding a photo's member

    /// The member holding a photo, with its place among the members; nil when none knows it.
    private func owner(of id: LibraryAsset.ID) -> (index: Int, source: any LibrarySource)? {
        if let index = owners[id], members.indices.contains(index) {
            return (index, members[index])
        }
        guard let index = members.firstIndex(where: { $0.asset(id: id) != nil }) else { return nil }
        owners[id] = index
        return (index, members[index])
    }

    private func source(of asset: LibraryAsset) throws -> any LibrarySource {
        guard let owner = owner(of: asset.id) else { throw LibrarySourceError.assetUnavailable }
        return owner.source
    }

    public func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        owner(of: id)?.source.asset(id: id)
    }

    public func index(of id: LibraryAsset.ID) -> Int? {
        guard let owner = owner(of: id), let row = owner.source.index(of: id) else { return nil }
        return merge.position(listing: owner.index, row: row)
    }

    // MARK: - What the library can do

    /// What every member can store: a decision one of them can't keep isn't offered.
    public var capabilities: Set<LibraryCapability> {
        members.dropFirst().reduce(members.first?.capabilities ?? []) { $0.intersection($1.capabilities) }
    }

    /// The filters every member honors. No other order than the two by date: listings sorted by
    /// rating or by name don't weave into one.
    public var queryCapabilities: Set<QueryCapability> {
        members.dropFirst().reduce(members.first?.queryCapabilities ?? []) { $0.intersection($1.queryCapabilities) }
            .subtracting([.sortByRating, .sortByFileName])
    }

    public var indexingProgress: IndexingProgress? {
        members.lazy.compactMap(\.indexingProgress).first
    }

    public var indexingNotice: String? {
        members.lazy.compactMap(\.indexingNotice).first
    }

    // MARK: - Places

    public var hasPlaces: Bool {
        members.contains { $0.hasPlaces }
    }

    public var placesVersion: Int {
        members.reduce(membersVersion) { $0 &+ $1.placesVersion }
    }

    public func locatedAssets() async -> [LocatedAsset] {
        var located: [LocatedAsset] = []
        for member in members where member.hasPlaces {
            await located.append(contentsOf: member.locatedAssets())
        }
        return located
    }

    // MARK: - One photo, asked of its member

    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize, fit: ThumbnailFit) async -> CGImage? {
        await owner(of: asset.id)?.source.thumbnail(for: asset, pixelSize: pixelSize, fit: fit)
    }

    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        await owner(of: asset.id)?.source.fullSizeImage(for: asset)
    }

    public func setRating(_ rating: Int, for asset: LibraryAsset) async throws {
        try await source(of: asset).setRating(rating, for: asset)
    }

    public func setFlag(_ flag: ItemFlag, for asset: LibraryAsset) async throws {
        try await source(of: asset).setFlag(flag, for: asset)
    }

    public func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws {
        try await source(of: asset).setKeywords(keywords, for: asset)
    }

    public func keywords(for asset: LibraryAsset) async -> [String] {
        await owner(of: asset.id)?.source.keywords(for: asset) ?? asset.keywords
    }

    public func captureDate(for asset: LibraryAsset) -> Date? {
        owner(of: asset.id)?.source.captureDate(for: asset) ?? asset.creationDate
    }

    public func setCaptureDate(_ date: Date?, for asset: LibraryAsset) async throws {
        try await source(of: asset).setCaptureDate(date, for: asset)
    }

    public func editingInput(for asset: LibraryAsset) async throws -> EditingInput {
        try await source(of: asset).editingInput(for: asset)
    }

    public func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws {
        try await source(of: asset).saveEdit(output, for: asset)
    }

    public func endEditing(_ asset: LibraryAsset) {
        owner(of: asset.id)?.source.endEditing(asset)
    }

    public func prioritize(_ asset: LibraryAsset) {
        owner(of: asset.id)?.source.prioritize(asset)
    }

    public func resourceInfo(for asset: LibraryAsset) async -> AssetResourceInfo {
        await owner(of: asset.id)?.source.resourceInfo(for: asset) ?? AssetResourceInfo(asset)
    }

    public func details(for asset: LibraryAsset, allowingDownload: Bool) async -> AssetDetails {
        await owner(of: asset.id)?.source.details(for: asset, allowingDownload: allowingDownload) ?? AssetDetails(asset)
    }

    /// Answers for the photos of members that have files; `hasFileURLs` stays false, since not every
    /// photo here has one.
    public func fileURL(for asset: LibraryAsset) -> URL? {
        owner(of: asset.id)?.source.fileURL(for: asset)
    }

    /// The member whose photo is at `index` warms its own thumbnails around it: the rows near it in
    /// the merged listing are mostly its neighbors.
    public func prefetchThumbnails(around index: Int, pixelSize: CGSize, fit: ThumbnailFit) {
        guard merge.entries.indices.contains(index) else { return }
        let entry = merge.entries[index]
        guard members.indices.contains(Int(entry.listing)) else { return }
        members[Int(entry.listing)].prefetchThumbnails(around: Int(entry.row), pixelSize: pixelSize, fit: fit)
    }

    /// Waits for the weavings asked so far; for tests.
    func waitUntilWoven() async {
        var seen = -1
        while seen != generation {
            seen = generation
            await weaving?.value
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
