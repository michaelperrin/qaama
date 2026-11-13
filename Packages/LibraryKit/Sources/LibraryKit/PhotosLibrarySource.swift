import CoreGraphics
import Foundation
import ImageIOKit
import ObjCSupport
import Observation
import os
import OSLog
import Photos
import UniformTypeIdentifiers

/// "Apple Photos library" source: lists photos and provides their images through PhotoKit.
///
/// Keeps the list in sync with the library through `PHPhotoLibraryChangeObserver`.
@Observable
public final class PhotosLibrarySource: LibrarySource {
    public private(set) var assets: AssetCollection = .empty
    /// The months of `assets`, when they are sorted by capture date: the first rows as soon as they
    /// are listed, every row once their dates are read in the background (see `rebuildTimeline`).
    public private(set) var timeline: DateTimeline?
    /// Bumped on every library change, so views reading a single asset refresh with the library.
    public private(set) var libraryVersion = 0
    public private(set) var access: PhotoLibraryAccess = .current
    /// Duration of the last full listing, for performance tracking.
    public private(set) var lastLoadDuration: Duration?

    public var displayName: String {
        album?.title ?? "Photos"
    }

    public var capabilities: Set<LibraryCapability> {
        [.rating, .keywords, .captureDate]
    }

    /// Date and favorite are native; rating filter and sort are too on macOS 27, confirmed by a probe at
    /// load time since PhotoKit doesn't document them. RAW and the search on names and keywords come
    /// from the local index, and so do the JPEG twins once it has found pairs stored as two photos.
    /// Flags don't exist in Photos.
    public var queryCapabilities: Set<QueryCapability> {
        var supported = nativeCapabilities
        if let index {
            supported.formUnion([.raw, .search])
            if !index.snapshot.twinIDs.isEmpty {
                supported.insert(.pairedJPEGs)
            }
        }
        return supported
    }

    private var nativeCapabilities: Set<QueryCapability> = [.favorite]

    /// Positions come from the index, which reads them from Photos' database.
    public var hasPlaces: Bool {
        index != nil
    }

    public var placesVersion: Int {
        membershipVersion &+ (index?.contentVersion ?? 0)
    }

    /// Bumped when the listing gains or loses photos. Not `libraryVersion`: Photos reports changes
    /// every second or two while it analyzes or syncs, and most leave the same photos listed.
    private var membershipVersion = 0

    /// The dates of the listing, read off the main actor (1.3 s measured for 74,000 photos) and kept
    /// until the listing gains, loses or reorders photos: Photos reports changes every second or two
    /// while it analyzes or syncs, and most leave every date as it was. Asked twice at once, the
    /// listing is read once.
    public func listingDates() async -> [Date?] {
        guard let fetchResult else { return [] }
        if let listingDatesCache, listingDatesCache.count == fetchResult.count {
            return listingDatesCache
        }
        if let reading = listingDatesReading, reading.result === fetchResult {
            return await reading.task.value
        }
        let clock = ContinuousClock()
        let start = clock.now
        // PhotoKit documents fetch results as safe to read from any thread; this one is only read there.
        let result = UncheckedSendable(fetchResult)
        let byModification = query.sort == .modificationDate
        let task = Task.detached(priority: .userInitiated) {
            var dates: [Date?] = []
            dates.reserveCapacity(result.value.count)
            PhotosFetchEnumeration.forEachAsset(in: result.value) { dates.append(byModification ? $0.modificationDate : $0.creationDate) }
            return dates
        }
        listingDatesReading = (fetchResult, task)
        let dates = await task.value
        // The listing moved on meanwhile: these dates are another listing's.
        if self.fetchResult === fetchResult {
            listingDatesCache = dates
        }
        if listingDatesReading?.result === fetchResult {
            listingDatesReading = nil
        }
        logger.notice("Listing dates: \(dates.count) read in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        return dates
    }

    /// The answer of `listingDates()` for the current listing, while it holds, and the reading under way.
    @ObservationIgnored private var listingDatesCache: [Date?]?
    @ObservationIgnored private var listingDatesReading: (result: PHFetchResult<PHAsset>, task: Task<[Date?], Never>)?

    /// The indexed positions of the photos the query lists.
    ///
    /// The whole library without a filter lists every indexed photo but the hidden JPEG twins: the
    /// index alone answers. Otherwise the listing's identifiers are read off the main actor and the
    /// positions kept are theirs (1.5 s measured for 74,000 photos, nearly all of it PhotoKit handing
    /// out identifiers); a group picked on the map doesn't narrow them, which costs one more listing.
    public func locatedAssets() async -> [LocatedAsset] {
        guard let index, let fetchResult else { return [] }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let located = try await index.locatedAssets()
            let shown: [LocatedAsset]
            if album == nil, search == nil, query.isUnfiltered {
                let hidden = query.includesPairedJPEGs ? [] : listedSnapshot.twinIDs
                shown = hidden.isEmpty ? located : await Task.detached(priority: .userInitiated) { located.filter { !hidden.contains($0.id) } }.value
            } else {
                // PhotoKit documents fetch results as safe to read from any thread; this one is only read there.
                let current = UncheckedSendable(fetchResult)
                var whole: PhotosListing?
                if query.onlyAssetIDs != nil {
                    whole = listing(searchMatches: search?.matches)
                    whole?.query.onlyAssetIDs = nil
                }
                shown = await Task.detached(priority: .userInitiated) { [whole] in
                    let listed = Set(PhotoKitIndexLibrary.identifiers(of: whole?.fetch() ?? current.value))
                    return located.filter { listed.contains($0.id) }
                }.value
            }
            logger.notice("Places: \(shown.count) listed photos have a position (\(located.count) in the index), read in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            return shown
        } catch {
            logger.error("Couldn't read the positions: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public var indexingProgress: IndexingProgress? {
        index?.progress
    }

    /// Search and the hiding of JPEG twins wait for the index; the RAW set is complete from the start.
    public var indexingNotice: String? {
        guard indexingProgress != nil else { return nil }
        if !searchText.isEmpty {
            return "Still indexing the Photos library: the search only covers the photos indexed so far."
        }
        if !query.rawOnly, !query.includesPairedJPEGs {
            return "Still indexing the Photos library: some JPEG twins of RAW photos may show until it finishes."
        }
        return nil
    }

    public var query = LibraryQuery.default {
        didSet {
            guard query != oldValue, fetchResult != nil else { return }
            queryChanged()
        }
    }

    private var fetchResult: PHFetchResult<PHAsset>?
    /// PHAssets fetched by identifier, kept for image requests and edits. Not observed: it is filled
    /// while views are being built, and mutating observed state there would invalidate them in a loop.
    @ObservationIgnored private var materialized: [String: PHAsset] = [:]
    /// Resource kinds per asset, found once per session; PhotoKit has no predicate for them.
    @ObservationIgnored private var resourceInfos: [String: AssetResourceInfo] = [:]
    private let imageManager = PHCachingImageManager()
    private var changeRelay: PhotoLibraryChangeRelay?
    /// Editing inputs kept alive while a photo is open: they hold the access to the original file.
    private var editingInputs: [String: PHContentEditingInput] = [:]
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosLibrarySource")

    /// The album this source shows, or nil for the whole library.
    public let album: PhotosAlbum?
    /// What PhotoKit can't filter on; shared by every Photos source. Nil leaves those filters out.
    private let index: PhotosIndex?
    /// The index answers the current listing was built with; a newer snapshot triggers a refetch.
    @ObservationIgnored private var listedSnapshot = PhotosIndexSnapshot()
    /// The text last searched in the index and the assets found for it; nil when nothing is searched.
    @ObservationIgnored private var search: (text: String, matches: [String])?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The reading of the dates in progress, and its number: a reading the listing has outrun is dropped.
    @ObservationIgnored private var timelineTask: Task<Void, Never>?
    @ObservationIgnored private var timelineGeneration = 0
    /// A listing costs tens of ms: one per pause in typing, not one per keystroke.
    private static let typingDelay = Duration.milliseconds(150)

    public init(album: PhotosAlbum? = nil, index: PhotosIndex? = nil) {
        self.album = album
        self.index = index
    }

    /// Requests access if needed, then loads the photos, newest first, and starts tracking changes.
    public func load() async {
        guard fetchResult == nil else { return }
        access = await PhotoLibraryAccess.request()
        logger.notice("Photo library access: \(String(describing: self.access), privacy: .public)")
        guard access == .authorized || access == .limited else {
            assets = .empty
            return
        }

        probeNativeQueries()
        // The RAW set and the pairs already known take a few tens of ms; the rest runs in the background.
        await index?.start()
        followIndex()
        if let index, !searchText.isEmpty {
            search = await (searchText, (try? index.search(searchText)) ?? [])
        }
        let clock = ContinuousClock()
        let start = clock.now
        let listing = listing(searchMatches: search?.matches)
        apply(listing.fetch(), for: listing)
        lastLoadDuration = clock.now - start
        logger.notice("Fetched \(self.assets.count) photos in \(self.lastLoadDuration!.formatted(.units(allowed: [.milliseconds])), privacy: .public)")

        if changeRelay == nil {
            changeRelay = PhotoLibraryChangeRelay { [weak self] change in
                self?.handle(change)
            }
        }
    }

    /// Sets the star rating (0 to 5) of a photo, stored natively by Photos (macOS 27).
    /// The list is refreshed through the change observer once Photos commits the change.
    public func setRating(_ rating: Int, for asset: LibraryAsset) async throws {
        guard let phAsset = phAsset(for: asset.id),
              let value = PHAsset.Rating(rawValue: min(max(rating, 0), 5)) else { return }
        // PhotoKit runs the change block on its own queue, so it must not inherit the main-actor isolation
        // this module defaults to. PHAsset is an immutable, Sendable snapshot and is safe to hand over.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: phAsset).rating = value
        }
        logger.notice("Rated \(asset.id, privacy: .public) with \(rating) stars")
    }

    public func captureDate(for asset: LibraryAsset) -> Date? {
        phAsset(for: asset.id)?.creationDate
    }

    /// Photos keeps the date in its database, apart from the original, as its own Adjust Date & Time
    /// does; the list is refreshed through the change observer. Photos has no "back to the file's date":
    /// a nil date is refused.
    public func setCaptureDate(_ date: Date?, for asset: LibraryAsset) async throws {
        guard let phAsset = phAsset(for: asset.id) else { throw LibrarySourceError.assetUnavailable }
        guard let date else { throw LibrarySourceError.editingFailed("Photos needs a date") }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: phAsset).creationDate = date
        }
        // The change observer drops it too, but only once Photos has told: a batch reads it before.
        materialized[asset.id] = nil
        logger.notice("Capture date of \(asset.id, privacy: .public) corrected")
    }

    /// Photos stores a RAW + JPEG pair as one asset with two resources. Listing them costs one request per
    /// asset, so it happens for the tiles on screen only and the answer is cached.
    public func resourceInfo(for asset: LibraryAsset) async -> AssetResourceInfo {
        if let cached = resourceInfos[asset.id] {
            return cached.pairing(with: asset)
        }
        guard let phAsset = phAsset(for: asset.id) else { return AssetResourceInfo(asset) }
        let info = await Task.detached {
            AssetResourceInfo(resources: PHAssetResource.assetResources(for: phAsset))
        }.value
        resourceInfos[asset.id] = info
        return info.pairing(with: asset)
    }

    /// Photos' database knows the file name, the dimensions, the date and the place (as the user may
    /// have corrected them in Photos, so they win over the header's). The camera settings are in the
    /// original's header, which is read only when the original is on this Mac: most are in iCloud, and
    /// selecting a photo in the grid must not download one. With `allowingDownload`, Photos fetches the
    /// whole original first, and keeps it on disk for as long as it sees fit.
    public func details(for asset: LibraryAsset, allowingDownload: Bool) async -> AssetDetails {
        guard let phAsset = phAsset(for: asset.id) else { return AssetDetails(asset) }
        let clock = ContinuousClock()
        let start = clock.now
        var details = AssetDetails(asset)
        if let known = resourceInfos[asset.id]?.originalFileName {
            details.fileName = known
        } else {
            details.fileName = await Task.detached { phAsset.extendedMetadata.originalFilename }.value
        }
        let original = await Self.originalHeader(of: phAsset, allowingDownload: allowingDownload)
        if let header = original.header {
            details.metadata = header
        } else {
            details.isOriginalInCloud = original.isMissing
        }
        // The date in Photos' database is the one the user sees and corrects; the header keeps the camera's.
        if let date = self.phAsset(for: asset.id)?.creationDate {
            details.metadata?.captureDate = date
        }
        if let place = phAsset.geoCoordinate {
            details.metadata?.location = place
        }
        let outcome = original.header != nil ? "header read" : (original.isMissing ? "original not on disk" : "no header")
        logger.notice("Details of \(asset.id, privacy: .public)\(allowingDownload ? " with download" : "", privacy: .public): \(outcome, privacy: .public) in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        if let failure = original.failure {
            logger.error("Original of \(asset.id, privacy: .public) unavailable: \(failure, privacy: .public)")
        }
        return details
    }

    /// The header of the original: from the disk when Photos has it there, from iCloud only when
    /// `allowingDownload` is true. `isMissing` tells that Photos handed no original over (it is in
    /// iCloud, or its download failed, with the reason in `failure`).
    /// Cancelling the task cancels the request: selections can move faster than Photos answers.
    private nonisolated static func originalHeader(of phAsset: PHAsset, allowingDownload: Bool) async
        -> (header: ImageMetadata?, isMissing: Bool, failure: String?)
    {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = allowingDownload
        // Same choice as for editing: the original when the last edit is Qaama's, so both show the same header.
        options.canHandleAdjustmentData = { @Sendable data in data.formatIdentifier == EditingFormat.identifier }

        let requestID = OSAllocatedUnfairLock<PHContentEditingInputRequestID?>(initialState: nil)
        // PHContentEditingInput isn't Sendable; PhotoKit hands it over once and only the header read below touches it.
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(input: UncheckedSendable<PHContentEditingInput>?, isMissing: Bool, failure: String?), Never>) in
                let id = phAsset.requestContentEditingInput(with: options) { @Sendable input, info in
                    // No input, and not because the selection moved on: the original isn't here.
                    let wasCancelled = (info[PHContentEditingInputCancelledKey] as? Bool) ?? false
                    let failure = (info[PHContentEditingInputErrorKey] as? NSError)?.localizedDescription
                    continuation.resume(returning: (input.map { UncheckedSendable($0) }, input == nil && !wasCancelled, failure))
                }
                requestID.withLock { $0 = id }
                // Cancelled before the request had an identifier to cancel.
                if Task.isCancelled {
                    phAsset.cancelContentEditingInputRequest(id)
                }
            }
        } onCancel: {
            if let id = requestID.withLock({ $0 }) {
                phAsset.cancelContentEditingInputRequest(id)
            }
        }
        guard let input = answer.input else { return (nil, answer.isMissing, answer.failure) }
        // The input holds the access to the file: it must live until the header is read.
        let header = await Task.detached(priority: .userInitiated) {
            input.value.fullSizeImageURL.flatMap { try? ImageMetadataReader.read($0) }
        }.value
        return (header, false, nil)
    }

    /// Keywords live in Photos' extended metadata, fetched per asset rather than for the whole listing.
    public func keywords(for asset: LibraryAsset) async -> [String] {
        guard let phAsset = phAsset(for: asset.id) else { return [] }
        return await Task.detached { phAsset.extendedMetadata.keywords }.value
    }

    public func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws {
        guard let phAsset = phAsset(for: asset.id) else { throw LibrarySourceError.assetUnavailable }
        let current = await Set(self.keywords(for: asset))
        let wanted = Set(keywords)
        let added = wanted.subtracting(current)
        let removed = current.subtracting(wanted)
        guard !added.isEmpty || !removed.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetChangeRequest(for: phAsset)
            added.forEach { request.addKeyword($0) }
            removed.forEach { request.removeKeyword($0) }
        }
        logger.notice("Keywords of \(asset.id, privacy: .public): +\(added.count) -\(removed.count)")
    }

    /// Thumbnail for a square of `pixelSize`; PhotoKit sizes it to fill or to fit that square.
    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize, fit: ThumbnailFit) async -> CGImage? {
        await requestImage(for: asset, targetSize: pixelSize, contentMode: fit.contentMode)
    }

    /// Full-resolution image as Photos delivers it (Photos adjustments included).
    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        await requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit)
    }

    /// Warms the thumbnail cache for photos about to appear on screen.
    /// Keeps PhotoKit's cache warm for a window of rows around what is on screen, and drops what scrolled
    /// far away. Called for every visible tile, so it only acts when the window moves by a few rows.
    /// PhotoKit caches by size and content mode: when the grid is zoomed or switches between square and
    /// whole thumbnails, what was cached is of no use and is dropped as a whole.
    public func prefetchThumbnails(around index: Int, pixelSize: CGSize, fit: ThumbnailFit) {
        guard let fetchResult else { return }
        let count = fetchResult.count
        guard count > 0 else { return }
        let request = PrefetchRequest(pixelSize: pixelSize, fit: fit)
        if request != prefetchedRequest {
            imageManager.stopCachingImagesForAllAssets()
            prefetched = 0 ..< 0
            prefetchedRequest = request
        }
        let desired = max(0, index - Self.prefetchWindow / 2) ..< min(count, index + Self.prefetchWindow)
        guard abs(desired.lowerBound - prefetched.lowerBound) >= Self.prefetchStep
            || abs(desired.upperBound - prefetched.upperBound) >= Self.prefetchStep
            || prefetched.isEmpty else { return }

        let options = Self.requestOptions()
        let toStart = desired.filter { !prefetched.contains($0) }.map { fetchResult.object(at: $0) }
        let toStop = prefetched.filter { !desired.contains($0) && $0 < count }.map { fetchResult.object(at: $0) }
        if !toStop.isEmpty {
            imageManager.stopCachingImages(for: toStop, targetSize: pixelSize, contentMode: fit.contentMode, options: options)
        }
        if !toStart.isEmpty {
            imageManager.startCachingImages(for: toStart, targetSize: pixelSize, contentMode: fit.contentMode, options: options)
        }
        prefetched = desired
    }

    /// Rows kept warm around the visible one, and how far the window must move before it is updated.
    private static let prefetchWindow = 60
    private static let prefetchStep = 10
    @ObservationIgnored private var prefetched: Range<Int> = 0 ..< 0
    /// What the warm thumbnails were asked at; a different request empties the cache.
    private struct PrefetchRequest: Equatable {
        var pixelSize: CGSize
        var fit: ThumbnailFit
    }

    @ObservationIgnored private var prefetchedRequest: PrefetchRequest?

    // MARK: - Editing (PHAdjustmentData)

    /// Asks Photos for the original (RAW included) and for Qaama's own adjustment data, if the photo
    /// was last edited here. Edits made by other apps are baked into the image Photos hands back.
    public func editingInput(for asset: LibraryAsset) async throws -> EditingInput {
        guard let phAsset = phAsset(for: asset.id) else { throw LibrarySourceError.assetUnavailable }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { @Sendable data in data.formatIdentifier == EditingFormat.identifier }

        // PHContentEditingInput isn't Sendable; PhotoKit hands it over once and we only touch it on the main actor afterwards.
        let input = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedSendable<PHContentEditingInput>, Error>) in
            phAsset.requestContentEditingInput(with: options) { @Sendable input, info in
                if let input {
                    continuation.resume(returning: UncheckedSendable(input))
                } else {
                    let reason = (info[PHContentEditingInputErrorKey] as? NSError)?.localizedDescription ?? "no original available"
                    continuation.resume(throwing: LibrarySourceError.editingFailed(reason))
                }
            }
        }.value
        editingInputs[asset.id] = input
        let recipeData = input.adjustmentData?.formatIdentifier == EditingFormat.identifier ? input.adjustmentData?.data : nil
        logger.notice("Editing input for \(asset.id, privacy: .public): file \(input.fullSizeImageURL?.pathExtension ?? "none", privacy: .public), recipe \(recipeData != nil)")
        return EditingInput(imageURL: input.fullSizeImageURL, image: input.displaySizeImage?.asCGImage, recipeData: recipeData)
    }

    /// Stores the recipe as `PHAdjustmentData` and the rendered JPEG as the photo's current version,
    /// the standard non-destructive path: Photos keeps the original and can revert at any time.
    public func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws {
        guard let phAsset = phAsset(for: asset.id) else { throw LibrarySourceError.assetUnavailable }
        guard let input = editingInputs[asset.id] else { throw LibrarySourceError.editingFailed("the photo wasn't opened for editing") }
        if output.isReset {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetChangeRequest(for: phAsset).revertAssetContentToOriginal()
            }
            logger.notice("Reverted \(asset.id, privacy: .public) to its original in Photos")
            return
        }

        let editingOutput = PHContentEditingOutput(contentEditingInput: input)
        editingOutput.adjustmentData = PHAdjustmentData(
            formatIdentifier: EditingFormat.identifier,
            formatVersion: EditingFormat.version,
            data: output.recipeData
        )
        do {
            try output.renderedJPEG.write(to: editingOutput.renderedContentURL, options: .atomic)
        } catch {
            throw LibrarySourceError.editingFailed(error.localizedDescription)
        }
        // Same story as above: the output is built here and consumed once by PhotoKit's change block.
        nonisolated(unsafe) let pendingOutput = editingOutput
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest(for: phAsset).contentEditingOutput = pendingOutput
        }
        logger.notice("Saved edit to Photos for \(asset.id, privacy: .public)")
    }

    /// Photos renders its thumbnails with the saved edit itself, so there is nothing to apply.
    public func savedRecipeData(for _: LibraryAsset) async -> Data? {
        nil
    }

    /// Releases the original file access once the editor closes.
    public func endEditing(_ asset: LibraryAsset) {
        editingInputs[asset.id] = nil
    }

    // MARK: - Private

    private func handle(_ change: PHChange) {
        guard let fetchResult, let details = change.changeDetails(for: fetchResult) else { return }
        // Nothing is materialized up front, so applying a change is just swapping the fetch result;
        // changed assets are dropped from the cache and re-read on their next access.
        for changed in details.changedObjects {
            materialized[changed.localIdentifier] = nil
            resourceInfos[changed.localIdentifier] = nil
        }
        for removed in details.removedObjects {
            materialized[removed.localIdentifier] = nil
        }
        let timelineIsOutdated = outdatesTimeline(details)
        // Modification dates move with any change; capture dates with the ones the timeline cares about.
        if timelineIsOutdated || query.sort != .captureDate {
            listingDatesCache = nil
        }
        if !details.hasIncrementalChanges || !details.insertedObjects.isEmpty || !details.removedObjects.isEmpty {
            membershipVersion += 1
        }
        apply(fetchResult: details.fetchResultAfterChanges)
        if timelineIsOutdated {
            // The months in place stay until the new ones are read: a few rows off for a moment.
            rebuildTimeline(showingFirstRows: false)
        }
        logger.notice("Applied library change (\(details.insertedObjects.count) inserted, \(details.removedObjects.count) removed, \(details.changedObjects.count) changed)")
    }

    /// What PhotoKit accepts natively isn't documented for ratings and keywords; an unsupported predicate
    /// raises an Objective-C exception, so each candidate is tried once behind a catcher.
    private func probeNativeQueries() {
        func accepts(_ configure: (PHFetchOptions) -> Void) -> Bool {
            let options = PHFetchOptions()
            options.fetchLimit = 1
            configure(options)
            var count = -1
            let exception = QAACatchException { count = PHAsset.fetchAssets(with: options).count }
            return exception == nil && count >= 0
        }
        var supported: Set<QueryCapability> = [.favorite]
        if accepts({ $0.predicate = NSPredicate(format: "rating >= %d", 1) }) {
            supported.insert(.rating)
        }
        if accepts({ $0.sortDescriptors = [NSSortDescriptor(key: "rating", ascending: false)] }) {
            supported.insert(.sortByRating)
        }
        nativeCapabilities = supported
        logger.notice("PhotoKit native queries: rating filter \(supported.contains(.rating)), rating sort \(supported.contains(.sortByRating))")
    }

    // MARK: - Search and index changes

    /// The words to look for in the index; empty without an index, which leaves search unsupported.
    private var searchText: String {
        index == nil ? "" : query.searchText.trimmingCharacters(in: .whitespaces)
    }

    private func queryChanged() {
        let text = searchText
        if text == search?.text ?? "" {
            searchTask?.cancel()
            refetch()
        } else if text.isEmpty {
            searchTask?.cancel()
            search = nil
            refetch()
        } else {
            runSearch(after: Self.typingDelay)
        }
    }

    /// Asks the index for the assets matching the search text, then lists them, both off the main actor
    /// so typing stays fluid. The listing in place stays until the answer is there.
    private func runSearch(after delay: Duration = .zero) {
        searchTask?.cancel()
        let text = searchText
        guard let index, !text.isEmpty else { return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                let clock = ContinuousClock()
                let start = clock.now
                let matches = try await index.search(text) ?? []
                guard let self, !Task.isCancelled else { return }
                // An index pass that changed nothing for this search isn't worth a new listing.
                if search?.text == text, search?.matches == matches, index.snapshot == listedSnapshot {
                    return
                }
                let found = clock.now
                let listing = listing(searchMatches: matches)
                let result = await Task.detached(priority: .userInitiated) { listing.fetch() }.value
                // The query moved on while PhotoKit was listing: a newer search or refetch takes over.
                guard !Task.isCancelled else { return }
                search = (text, matches)
                apply(result, for: listing)
                logger.notice("Search: \(matches.count) matches in \((found - start).formatted(.units(allowed: [.milliseconds])), privacy: .public), \(self.assets.count) photos listed in \((clock.now - found).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            } catch {
                self?.logger.error("Search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Refetches when the index learns something the current listing was built without: the RAW set
    /// changed, a pass found RAW + JPEG pairs, or names and keywords being searched were read.
    private func followIndex() {
        guard let index else { return }
        withObservationTracking {
            _ = index.snapshot
            _ = index.contentVersion
        } onChange: { [weak self] in
            Task { @MainActor in self?.indexChanged() }
        }
    }

    private func indexChanged() {
        if let index, fetchResult != nil {
            if search != nil {
                runSearch()
            } else if index.snapshot != listedSnapshot {
                refetch()
            }
        }
        followIndex()
    }

    // MARK: - Listing

    /// The current query, index answers and search results, frozen for one fetch.
    private func listing(searchMatches: [String]?) -> PhotosListing {
        PhotosListing(query: query, native: nativeCapabilities, index: index?.snapshot, searchMatches: searchMatches, albumID: album?.id)
    }

    private func refetch() {
        probeNativeQueries()
        let clock = ContinuousClock()
        let start = clock.now
        let listing = listing(searchMatches: search?.matches)
        apply(listing.fetch(), for: listing)
        logger.notice("Refetched \(self.assets.count) photos in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    private func apply(_ result: PHFetchResult<PHAsset>, for listing: PhotosListing) {
        listedSnapshot = listing.index ?? PhotosIndexSnapshot()
        listingDatesCache = nil
        membershipVersion += 1
        apply(fetchResult: result)
        rebuildTimeline(showingFirstRows: true)
    }

    // MARK: - Timeline

    /// Reads the dates of the listing again, off the main actor (a second or two for a large library),
    /// and publishes its months when done. With `showingFirstRows`, for a listing that has nothing to
    /// do with the previous one, the months of the first rows are read at once and replace the timeline
    /// in place; the grid then keeps its top rows as they are when the rest arrives.
    private func rebuildTimeline(showingFirstRows: Bool) {
        timelineTask?.cancel()
        timelineTask = nil
        timelineGeneration += 1
        guard query.sort == .captureDate, let fetchResult else {
            timeline = nil
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        if showingFirstRows {
            let first = PhotosTimeline.firstRows(of: fetchResult)
            timeline = first
            // A short listing (an album, a search) is read whole already.
            if first.isComplete {
                return
            }
        }
        let firstRows = clock.now - start
        let generation = timelineGeneration
        // PhotoKit documents fetch results as safe to read from any thread; this one is only read there.
        let result = UncheckedSendable(fetchResult)
        timelineTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let complete = PhotosTimeline.complete(for: result.value) else { return }
            await self?.publish(complete, generation: generation, firstRows: firstRows, total: clock.now - start)
        }
    }

    private func publish(_ complete: DateTimeline, generation: Int, firstRows: Duration, total: Duration) {
        guard generation == timelineGeneration else { return }
        timelineTask = nil
        if complete != timeline {
            timeline = complete
        }
        logger.notice("Timeline: \(complete.sections.count) months of \(complete.count) photos in \(total.formatted(.units(allowed: [.milliseconds])), privacy: .public) (first rows in \(firstRows.formatted(.units(allowed: [.milliseconds])), privacy: .public))")
    }

    /// Whether a change of the library moved photos between months or rows. Photos reports changes
    /// every second or two while it analyzes or syncs; most touch neither the rows nor the dates, and
    /// reading 74,000 dates again for each would never end.
    private func outdatesTimeline(_ details: PHFetchResultChangeDetails<PHAsset>) -> Bool {
        guard query.sort == .captureDate else { return false }
        guard details.hasIncrementalChanges else { return true }
        if !details.insertedObjects.isEmpty || !details.removedObjects.isEmpty || details.hasMoves {
            return true
        }
        // Same rows. A reading in progress stays valid for them; once done, a date corrected without
        // moving its photo past another may still have left its month.
        guard timelineTask == nil, let timeline, timeline.isComplete, let rows = details.changedIndexes else { return false }
        for (row, asset) in zip(rows, details.changedObjects) {
            let month = asset.creationDate.map { YearMonth($0) }
            if timeline.section(containing: row)?.month != month {
                return true
            }
        }
        return false
    }

    /// Exposes the fetch result as a lazy collection: a row is built only when the grid asks for it.
    private func apply(fetchResult result: PHFetchResult<PHAsset>) {
        fetchResult = result
        libraryVersion += 1
        // Indices moved: forget the warm window; the next visible tile rebuilds it.
        imageManager.stopCachingImagesForAllAssets()
        prefetched = 0 ..< 0
        // The row closure must stay free of side effects: SwiftUI may walk the whole collection.
        let snapshot = listedSnapshot
        assets = AssetCollection(count: result.count) { index in
            Self.makeAsset(result.object(at: index), snapshot)
        }
    }

    public func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        // Register the caller's dependency on the library: the cache below is not observed.
        _ = libraryVersion
        return phAsset(for: id).map { Self.makeAsset($0, listedSnapshot) }
    }

    /// Asks the fetch result itself: no need to materialize every row of a large library.
    public func index(of id: LibraryAsset.ID) -> Int? {
        guard let fetchResult, let asset = phAsset(for: id) else { return nil }
        let index = fetchResult.index(of: asset)
        return index == NSNotFound ? nil : index
    }

    /// The PHAsset behind an identifier: from the rows already shown, or fetched on its own (a few ms).
    private func phAsset(for id: String) -> PHAsset? {
        if let cached = materialized[id] {
            return cached
        }
        guard let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        materialized[id] = fetched
        return fetched
    }

    private static func makeAsset(_ asset: PHAsset, _ snapshot: PhotosIndexSnapshot) -> LibraryAsset {
        LibraryAsset(
            id: asset.localIdentifier,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            creationDate: asset.creationDate,
            isFavorite: asset.isFavorite,
            rating: asset.rating.rawValue,
            modificationDate: asset.modificationDate,
            hasEdit: asset.hasAdjustments,
            isRAW: snapshot.rawIDs.contains(asset.localIdentifier),
            pairedAssetID: snapshot.pairedIDs[asset.localIdentifier]
        )
    }

    private func requestImage(for asset: LibraryAsset, targetSize: CGSize, contentMode: PHImageContentMode) async -> CGImage? {
        guard let phAsset = phAsset(for: asset.id) else { return nil }
        let options = Self.requestOptions()
        return await withCheckedContinuation { continuation in
            // Delivered on an arbitrary queue: the handler must stay out of the main-actor isolation this module defaults to.
            imageManager.requestImage(for: phAsset, targetSize: targetSize, contentMode: contentMode, options: options) { @Sendable image, info in
                // In high-quality delivery mode PhotoKit calls this block once, unless the request is cancelled.
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image?.asCGImage)
            }
        }
    }

    private static func requestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return options
    }
}

private nonisolated extension ThumbnailFit {
    var contentMode: PHImageContentMode {
        switch self {
        case .fill: .aspectFill
        case .fit: .aspectFit
        }
    }
}

nonisolated extension AssetResourceInfo {
    /// Reads what stands behind a Photos asset from its resources: the original and its alternate (the
    /// other half of a RAW + JPEG pair); renders and adjustment data don't count.
    init(resources: [PHAssetResource]) {
        let photos = resources.filter { $0.type == .photo || $0.type == .alternatePhoto }
        let raw = photos.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
        let other = photos.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == false }
        let name = (photos.first { $0.type == .photo } ?? photos.first)?.filename
        self.init(isRAW: raw, hasJPEGTwin: raw && other, originalFileName: name)
    }

    /// A RAW whose JPEG twin is a separate photo has no alternate resource, but it is still a pair.
    func pairing(with asset: LibraryAsset) -> AssetResourceInfo {
        var info = self
        if isRAW, asset.pairedAssetID != nil {
            info.hasJPEGTwin = true
        }
        return info
    }
}
