import CoreGraphics
import Foundation
import Observation
import OSLog

/// The photos on a card or a camera, shown like a library so the grid can browse them before an
/// import. Nothing is stored about them: no rating, no edit, no catalog.
///
/// The device announces its files one by one for a long while (measured: 1,256 files in 14 to 25 s),
/// in no useful order. The photos are listed once it has announced them all, newest first: a
/// listing that grew as they came had every row change photo several times a second (tried first,
/// 2026-11-19). Meanwhile `listingProgress` says how many photos to expect, which the device lets
/// one work out within a second, so the view can lay out as many empty thumbnails.
///
/// Thumbnails come in two steps, both through `CameraRequestQueue`: the one the camera embedded in
/// the file's header (`quickThumbnail`), then the one the grid asked for, which the device reads
/// the whole file for.
@Observable
public final class CameraLibrarySource: LibrarySource, Identifiable {
    /// How far the reading of the device is.
    public enum State: Hashable, Sendable {
        /// Not opened yet: `load()` does it.
        case idle
        case listing
        case listed
        /// The device couldn't be read, with the reason; or it was pulled out.
        case unavailable(String)
    }

    public let id: String
    public let displayName: String
    public let kind: CameraDeviceKind
    public private(set) var assets: AssetCollection = .empty
    public private(set) var timeline: DateTimeline?
    public private(set) var lastLoadDuration: Duration?
    public private(set) var state = State.idle
    /// While the device is being read: the photos found so far and how many to expect in all. Nil
    /// before the device has said enough to tell, and once the photos are listed.
    public private(set) var listingProgress: IndexingProgress?
    /// While the device is being read: the photos found so far, in the order it announced them,
    /// which is no order at all. For showing that something is coming: their places in `assets`
    /// are only known once every photo is. Brought up to date with `listingProgress`, not with each
    /// file, and emptied once the photos are listed. A RAW and its JPEG are still two photos here.
    public private(set) var foundPhotos: [LibraryAsset] = []
    /// The import going on from this device, or the last one made; nil before the first.
    public private(set) var currentImport: CameraImport?
    /// How many videos the device holds: they aren't listed, the grid shows photos only.
    public private(set) var movieCount = 0
    /// How many of its videos weren't imported yet: what an import that takes the videos brings.
    public private(set) var newMovieCount = 0
    /// How many photos the device holds that weren't imported yet.
    public private(set) var newPhotoCount = 0
    /// How many photos the device holds, listed or not (`hidesImported`).
    public private(set) var photoCount = 0
    /// Leaves the photos imported already out of the listing: only what is left to import shows.
    public var hidesImported = false {
        didSet {
            if hidesImported != oldValue, state == .listed {
                publish()
            }
        }
    }

    /// Nothing is stored about the photos; they can be deleted from the device where it allows
    /// it (not a card whose lock is on), which is known once it is listed.
    public var capabilities: Set<LibraryCapability> {
        state == .listed && connection.canDelete ? [.deletion] : []
    }

    public var queryCapabilities: Set<QueryCapability> {
        []
    }

    /// Kept, but nothing of it is honored: a device lists its photos newest first, all of them.
    public var query = LibraryQuery.default

    private let connection: any CameraConnection
    /// What was imported so far, to tell the photos of this device that were already.
    private let history: ImportHistory?
    private let queue = CameraRequestQueue()
    private var files: [CameraFile.ID: CameraFile] = [:]
    private var byID: [LibraryAsset.ID: LibraryAsset] = [:]
    /// The photos among `files`, videos left aside, as they are announced; emptied once listed.
    private var announced: [LibraryAsset] = []
    /// How many photos `files` holds, a RAW and its JPEG counted apart: what the listing in
    /// progress goes by.
    private var announcedCount = 0
    private var listingStart = ContinuousClock.now
    /// Decoded thumbnails; the system drops them under memory pressure.
    private let quickCache = NSCache<NSString, CGImage>()
    private let sharpCache = NSCache<NSString, CGImage>()
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "CameraLibrarySource")

    public init(connection: any CameraConnection, history: ImportHistory? = nil) {
        self.connection = connection
        self.history = history
        id = connection.id
        displayName = connection.name
        kind = connection.kind
        // About 80 kB a decoded embedded thumbnail, and a megabyte or more for those of the grid.
        quickCache.totalCostLimit = 64_000_000
        sharpCache.totalCostLimit = 256_000_000
    }

    public func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        byID[id]
    }

    // MARK: - Listing

    public func load() async {
        guard state == .idle else { return }
        state = .listing
        listingStart = .now
        connection.onEvent = { [weak self] event in self?.receive(event) }
        connection.open()
    }

    /// The device was pulled out: what is listed stays on screen, nothing more can be asked.
    func disconnect() {
        connection.onEvent = nil
        connection.close()
        endListing()
        state = .unavailable("“\(displayName)” was disconnected.")
    }

    private func receive(_ event: CameraEvent) {
        switch event {
        case let .added(added):
            for file in added {
                if files.updateValue(file, forKey: file.id) == nil, !file.isMovie {
                    announcedCount += 1
                    if state == .listing {
                        announced.append(LibraryAsset(file))
                    }
                }
            }
            // A file that comes later (a camera that just took a picture) shows at once.
            if state == .listed {
                publish()
            }
        case let .progress(fraction):
            guard state == .listing else { return }
            let expected = Self.expectedCount(found: announcedCount, fraction: fraction, previous: listingProgress?.total)
            listingProgress = expected.map { IndexingProgress(done: announcedCount, total: $0) }
            foundPhotos = announced
        case let .removed(ids):
            for id in ids {
                if let removed = files.removeValue(forKey: id), !removed.isMovie {
                    announcedCount -= 1
                    announced.removeAll { $0.id == id }
                }
            }
            if state == .listed {
                publish()
            }
        case .listed:
            publish()
            endListing()
            state = .listed
            let duration = ContinuousClock.now - listingStart
            lastLoadDuration = duration
            logger.notice("Listed \(self.displayName, privacy: .public): \(self.assets.count) photos, \(self.movieCount) videos, in \(duration.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)")
        case let .failed(message):
            logger.error("Couldn't read \(self.displayName, privacy: .public): \(message, privacy: .public)")
            endListing()
            state = .unavailable(message)
        }
    }

    /// Drops what only served while the device was being read.
    private func endListing() {
        listingProgress = nil
        foundPhotos = []
        announced = []
    }

    /// Lists the photos of the files known so far, those imported already marked as such.
    private func publish() {
        var listing = CameraListing(files: files.values)
        if let history {
            listing.markImported { id in files[id].map { history.contains(ImportedFileSignature($0)) } ?? false }
        }
        movieCount = listing.movieCount
        newMovieCount = newMovies().count
        photoCount = listing.assets.count { !$0.isVideo }
        newPhotoCount = listing.assets.count { !$0.isVideo && !$0.isImported }
        let shown = hidesImported ? listing.assets.filter { !$0.isImported } : listing.assets
        byID = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0) })
        assets = AssetCollection(shown)
        timeline = DateTimeline(dates: shown.map(\.creationDate))
    }

    /// The videos that weren't imported yet, oldest first. They are never listed: the grid shows
    /// photos only.
    private func newMovies() -> [CameraFile] {
        files.values.filter { file in file.isMovie && history?.contains(ImportedFileSignature(file)) != true }
            .sorted { ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id) }
    }

    /// The history of imports changed: the photos are marked again.
    func refreshImported() {
        if state == .listed {
            publish()
        }
    }

    /// How many photos the device will have announced in the end, from how many it has so far and
    /// the part of its files it says that is; nil while it has said too little to tell.
    ///
    /// Not before a tenth is announced: the device's own count runs ahead of the files it has
    /// handed over, by a few dozen, which at the very start gives half the real figure (measured:
    /// 560, 950 then 1,129 in the first second, 1,188 from the second on, for 1,233 photos). And it
    /// counts in whole percents, so the figure wobbles by a percent or so from one to the next. The
    /// first estimate is kept unless a later one is clearly another: the empty thumbnails laid out
    /// from it must not come and go.
    nonisolated static func expectedCount(found: Int, fraction: Double, previous: Int?) -> Int? {
        guard fraction >= 0.1, found > 0 else { return previous }
        let estimate = max(found, Int((Double(found) / min(fraction, 1)).rounded()))
        if let previous, previous >= found, abs(estimate - previous) * 20 <= previous {
            return previous
        }
        return estimate
    }

    // MARK: - Thumbnails

    /// The thumbnail embedded in the file's header: small (160 px) but read in a fraction of the
    /// time. For a RAW shot with a JPEG, the JPEG's, where cameras are known to put one.
    public func quickThumbnail(for asset: LibraryAsset) async -> CGImage? {
        let key = asset.id as NSString
        if let cached = quickCache.object(forKey: key) {
            return cached
        }
        for fileID in [asset.pairedAssetID, asset.id].compactMap(\.self) {
            let head = await queue.run(.quick) { await connection.head(of: fileID, length: CameraThumbnails.headLength) }
            // Unknown dimensions (0) leave the thumbnail as it is.
            let ratio = asset.pixelWidth > 0 && asset.pixelHeight > 0 ? asset.aspectRatio : 0
            let image = await Self.decode {
                CameraThumbnails.embedded(inHead: head ?? Data()).map { CameraThumbnails.cropped($0, toAspectRatio: ratio) }
            }
            guard let image else { continue }
            quickCache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
        return nil
    }

    public func thumbnail(for asset: LibraryAsset, pixelSize: CGSize, fit _: ThumbnailFit) async -> CGImage? {
        await image(of: asset, maxPixelSize: Int(max(pixelSize.width, pixelSize.height).rounded(.up)), lane: .slow)
    }

    /// As large as devices were seen to serve: the photo itself takes a copy of the file.
    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        await preview(for: asset, maxPixelSize: Self.largestPreview)
    }

    /// The photo for looking at it large, `maxPixelSize` on its long edge (see `previewPixels`):
    /// asked of the device ahead of the grid's thumbnails, and kept like them.
    public func preview(for asset: LibraryAsset, maxPixelSize: Int) async -> CGImage? {
        await image(of: asset, maxPixelSize: maxPixelSize, lane: .shown)
    }

    /// The largest image devices were seen to serve without the file being copied (JPEG and RAF).
    public nonisolated static let largestPreview = 4096

    /// The size to ask a preview at, for a view whose long edge is that many pixels: the next step
    /// of 1024, so that resizing the window a little doesn't read the file again.
    public nonisolated static func previewPixels(forLongEdge pixels: Double) -> Int {
        let step = 1024.0
        return min(max(Int((pixels / step).rounded(.up) * step), Int(step)), largestPreview)
    }

    private func image(of asset: LibraryAsset, maxPixelSize: Int, lane: CameraRequestQueue.Lane) async -> CGImage? {
        guard files[asset.id] != nil, maxPixelSize > 0 else { return nil }
        let key = "\(asset.id)#\(maxPixelSize)" as NSString
        if let cached = sharpCache.object(forKey: key) {
            return cached
        }
        return await queue.run(lane) {
            // Read by another request while this one waited for its turn (a preview warmed in
            // advance, then asked for): the device isn't asked twice. Which is why the image is
            // decoded and kept before the turn is given back.
            if let cached = sharpCache.object(forKey: key) {
                return cached
            }
            guard let data = await connection.thumbnailData(of: asset.id, maxPixelSize: maxPixelSize),
                  let image = await Self.decode({ CameraThumbnails.image(from: data) })
            else { return nil }
            sharpCache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
    }

    /// Decoding is CPU work: off the main actor.
    private nonisolated static func decode(_ work: @Sendable @escaping () -> CGImage?) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    // MARK: - Importing

    /// Starts copying photos to a destination called `destinationName`, and returns the import to
    /// follow. A RAW shown with its JPEG brings both files: into the same subfolder of a folder, as
    /// one photo of a library. `secondCopy` is a folder every file is copied to as well, filed by
    /// day: another disk, for a backup. Nil while another import from this device is going on.
    /// `keywords` are given to every photo copied into a folder, in a sidecar next to it (a library
    /// takes its own through its `ImportDestination`). `includingVideos` brings the device's videos that weren't imported yet as well, after the
    /// photos: filed like them in a folder, as videos in a library.
    public func startImport(of assets: [LibraryAsset], into destination: ImportDestination, named destinationName: String,
                            secondCopy: URL? = nil, includingVideos: Bool = false, keywords: [String] = []) -> CameraImport?
    {
        guard currentImport?.isFinished != false else { return nil }
        let videos = includingVideos ? newMovies().map { LibraryAsset(id: $0.id, pixelWidth: 0, pixelHeight: 0, creationDate: $0.creationDate, isFavorite: false) } : []
        // The videos asked for by hand count as videos too, and none comes twice.
        let assets = assets + videos.filter { video in !assets.contains { $0.id == video.id } }
        let videoIDs = Set(assets.filter { files[$0.id]?.isMovie == true }.map(\.id))
        let job = CameraImport(deviceName: displayName, destinationName: destinationName, total: assets.count)
        currentImport = job
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Import-\(job.id.uuidString)", isDirectory: true)
        job.start { [weak self] job in
            let clock = ContinuousClock()
            let start = clock.now
            for asset in assets {
                guard let self, !Task.isCancelled, case .listed = state else { break }
                let importedBefore = job.importedCount
                defer {
                    if videoIDs.contains(asset.id), job.importedCount > importedBefore {
                        job.countVideo()
                    }
                }
                switch destination {
                case let .folder(folder, layout):
                    await importPhoto(asset, into: folder, layout: layout, secondCopy: secondCopy, keywords: keywords, staging: staging, job: job)
                case let .library(makePhoto):
                    await importPhoto(asset, with: makePhoto, secondCopy: secondCopy, staging: staging, job: job)
                }
            }
            try? FileManager.default.removeItem(at: staging)
            self?.logger.notice("Imported \(job.imported.count) files of \(job.done) photos in \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public); \(job.alreadyThere) already there, \(job.failures.count) failures")
        }
        return job
    }

    private func importPhoto(_ asset: LibraryAsset, into folder: URL, layout: ImportLayout, secondCopy: URL?, keywords: [String], staging: URL,
                             job: CameraImport) async
    {
        let directory = layout.subfolder(for: asset.creationDate).map { folder.appendingPathComponent($0, isDirectory: true) } ?? folder
        let copyDirectory = secondCopy.map { CameraImportFiles.secondCopyDirectory(in: $0, for: asset.creationDate) }
        var copied: [URL] = []
        var skipped = 0
        var errors: [String] = []
        // The files that are at the destination now, copied or found there; and those of them
        // whose second copy, if asked for, is there too.
        var arrived: [CameraFile] = []
        var safe: [CameraFile.ID] = []
        for file in [asset.id, asset.pairedAssetID].compactMap(\.self).compactMap({ files[$0] }) {
            // File system work, however short, stays off the main actor.
            let (placement, copyPlacement) = await Task.detached {
                (CameraImportFiles.placement(name: file.name, byteSize: file.byteSize, in: directory),
                 copyDirectory.map { CameraImportFiles.placement(name: file.name, byteSize: file.byteSize, in: $0) })
            }.value
            // Read from the device unless it is everywhere it should be already.
            if placement == .alreadyThere, copyPlacement == nil || copyPlacement == .alreadyThere {
                skipped += 1
                arrived.append(file)
                safe.append(file.id)
                continue
            }
            let result: Result<CameraImportFiles.Placed, any Error>? = await queue.run(.copy) {
                do {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let downloaded = try await connection.download(file.id, into: staging)
                    return try await .success(Task.detached {
                        try CameraImportFiles.place(downloaded, expectedSize: file.byteSize, at: placement, secondCopy: copyPlacement)
                    }.value)
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case let .success(placed):
                if let installed = placed.installed {
                    copied.append(installed)
                    // The photo's own file carries its keywords, not the JPEG shot with a RAW, nor a video.
                    if file.id == asset.id, !file.isMovie, !keywords.isEmpty {
                        await Task.detached { try? Sidecar(keywords: keywords).write(forImageAt: installed) }.value
                    }
                } else {
                    skipped += 1
                }
                arrived.append(file)
                if let failure = placed.secondCopyError {
                    errors.append(failure)
                } else {
                    safe.append(file.id)
                }
            case let .failure(error): errors.append(error.localizedDescription)
            // Cancelled before its turn: the photo isn't counted as gone through.
            case nil: return
            }
        }
        job.record(copied: copied, skipped: skipped, errors: errors, files: arrived, removable: safe)
    }

    /// Copies the files of one photo into a folder of their own, checks them, makes their second
    /// copies where wanted, and hands them to the library. Nothing is handed over unless every
    /// file came whole.
    private func importPhoto(_ asset: LibraryAsset, with makePhoto: @Sendable (ImportedPhoto) async throws -> String, secondCopy: URL?,
                             staging: URL, job: CameraImport) async
    {
        let directory = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copyDirectory = secondCopy.map { CameraImportFiles.secondCopyDirectory(in: $0, for: asset.creationDate) }
        var photo = ImportedPhoto(files: [])
        var errors: [String] = []
        var safe: [CameraFile.ID] = []
        let photoFiles = [asset.id, asset.pairedAssetID].compactMap(\.self).compactMap { files[$0] }
        for file in photoFiles {
            let result: Result<(url: URL, secondCopyError: String?), any Error>? = await queue.run(.copy) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let downloaded = try await connection.download(file.id, into: directory)
                    let failure = try await Task.detached { () -> String? in
                        try CameraImportFiles.check(downloaded, expectedSize: file.byteSize)
                        guard let copyDirectory, case let .copy(copy) = CameraImportFiles.placement(name: file.name, byteSize: file.byteSize, in: copyDirectory) else { return nil }
                        do {
                            try FileManager.default.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
                            try FileManager.default.copyItem(at: downloaded, to: copy)
                            return nil
                        } catch {
                            return CameraImportError.secondCopyFailed(file.name, error.localizedDescription).localizedDescription
                        }
                    }.value
                    return .success((downloaded, failure))
                } catch {
                    return .failure(error)
                }
            }
            switch result {
            case let .success(downloaded):
                photo.files.append(ImportedPhoto.File(url: downloaded.url, name: file.name, isRAW: file.isRAW, isMovie: file.isMovie))
                if let failure = downloaded.secondCopyError {
                    errors.append(failure)
                } else {
                    safe.append(file.id)
                }
            case let .failure(error): return job.record(errors: [error.localizedDescription])
            case nil: return
            }
        }
        do {
            try await job.record(photoID: makePhoto(photo), errors: errors, files: photoFiles, removable: safe)
        } catch {
            job.record(errors: errors + [error.localizedDescription])
        }
    }

    /// Deletes from the device the files an import brought, or found already at the destination:
    /// never one that failed, nor one the import didn't get to. For good, as any deletion from a
    /// device. Returns how many files were deleted.
    @discardableResult
    public func deleteImported(by job: CameraImport) async throws -> Int {
        guard job.isFinished, capabilities.contains(.deletion) else { throw LibrarySourceError.unsupported(.deletion) }
        let ids = job.importedFileIDs.filter { files[$0] != nil }
        guard !ids.isEmpty else { return 0 }
        let result: Result<[CameraFile.ID], any Error>? = await queue.run(.copy) {
            do {
                return try await .success(connection.delete(ids))
            } catch {
                return .failure(error)
            }
        }
        guard let result else { return 0 }
        do {
            let deleted = try result.get()
            receive(.removed(deleted))
            logger.notice("Deleted \(deleted.count) imported files from \(self.displayName, privacy: .public)")
            return deleted.count
        } catch {
            throw LibrarySourceError.deletionFailed(error.localizedDescription)
        }
    }

    /// Ejects the device: it then leaves the list of devices by itself.
    public func eject() async throws {
        try await connection.eject()
    }

    // MARK: - Deleting

    /// Deletes photos from the device, a RAW with the JPEG shot with it. For good: a card has no
    /// Trash, so no undo is registered, as for the Photos library; the caller asks first
    /// (`deletionNotice`).
    @discardableResult
    public func delete(_ assets: [LibraryAsset], undoManager _: UndoManager?) async throws -> Bool {
        guard capabilities.contains(.deletion) else { throw LibrarySourceError.unsupported(.deletion) }
        let ids = assets.flatMap { [$0.id, $0.pairedAssetID].compactMap(\.self) }.filter { files[$0] != nil }
        guard !ids.isEmpty else { throw LibrarySourceError.assetUnavailable }
        let result: Result<[CameraFile.ID], any Error>? = await queue.run(.shown) {
            do {
                return try await .success(connection.delete(ids))
            } catch {
                return .failure(error)
            }
        }
        guard let result else { return false }
        let deleted: [CameraFile.ID]
        do {
            deleted = try result.get()
        } catch {
            throw LibrarySourceError.deletionFailed(error.localizedDescription)
        }
        // The device tells too, a moment later: the listing doesn't wait for it.
        receive(.removed(deleted))
        logger.notice("Deleted \(deleted.count) of \(ids.count) files from \(self.displayName, privacy: .public)")
        if deleted.count < ids.count {
            throw LibrarySourceError.deletionFailed("\(ids.count - deleted.count) of \(ids.count) files couldn't be deleted from “\(displayName)”.")
        }
        return true
    }

    public func deletionNotice(for assets: [LibraryAsset]) -> String? {
        let what = assets.count == 1 ? "It will be deleted" : "They will be deleted"
        return "\(what) from “\(displayName)” for good: this can't be undone."
    }

    // MARK: - What a device doesn't do

    public func setRating(_: Int, for _: LibraryAsset) async throws {
        throw LibrarySourceError.unsupported(.rating)
    }

    public func editingInput(for _: LibraryAsset) async throws -> EditingInput {
        throw LibrarySourceError.unsupported(.editing)
    }

    public func saveEdit(_: EditingOutput, for _: LibraryAsset) async throws {
        throw LibrarySourceError.unsupported(.editing)
    }
}

/// The photos a device's files make, newest first.
///
/// A RAW and the JPEG shot with it (same folder, same name but for the extension) show as one photo,
/// the RAW, as everywhere else in the app. Videos are listed too, marked as such, and counted.
nonisolated struct CameraListing {
    private(set) var assets: [LibraryAsset] = []
    private(set) var movieCount = 0

    /// Marks the photos whose file was imported already, as `isImported` says of a file. A RAW
    /// shown with its JPEG counts as imported once the RAW is.
    mutating func markImported(_ isImported: (CameraFile.ID) -> Bool) {
        for index in assets.indices {
            assets[index].isImported = isImported(assets[index].id)
        }
    }

    init(files: some Sequence<CameraFile>) {
        let files = Array(files)
        var photos: [CameraFile] = []
        for file in files {
            if file.isMovie {
                movieCount += 1
            } else {
                photos.append(file)
            }
        }
        // The JPEG twin of each RAW, by what their identifiers share.
        var jpegByStem: [String: CameraFile.ID] = [:]
        for file in photos where !file.isRAW {
            jpegByStem[file.stem] = file.id
        }
        var twins: [CameraFile.ID: CameraFile.ID] = [:]
        for file in photos where file.isRAW {
            if let twin = jpegByStem[file.stem] {
                twins[file.id] = twin
            }
        }
        let hidden = Set(twins.values)
        // The videos are listed among the photos, by date, each marked as one.
        assets = (photos.filter { !hidden.contains($0.id) }.map { LibraryAsset($0, twin: twins[$0.id]) }
            + files.filter(\.isMovie).map { file in
                var video = LibraryAsset(file)
                video.isVideo = true
                return video
            })
            // Newest first; the identifier settles the photos of one second, and those without a date.
            .sorted { lhs, rhs in
                let (left, right) = (lhs.creationDate ?? .distantPast, rhs.creationDate ?? .distantPast)
                return left == right ? lhs.id < rhs.id : left > right
            }
    }
}

private nonisolated extension LibraryAsset {
    /// The photo a device's file is, with the JPEG shot with it when it is a RAW that has one.
    init(_ file: CameraFile, twin: CameraFile.ID? = nil) {
        self.init(id: file.id, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight, creationDate: file.creationDate,
                  isFavorite: false, isRAW: file.isRAW, pairedAssetID: twin)
    }
}
