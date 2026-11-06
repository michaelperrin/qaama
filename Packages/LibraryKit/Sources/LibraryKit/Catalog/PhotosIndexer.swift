import Foundation
import OSLog

/// What the index reads about one asset of the photo library.
public nonisolated struct PhotosAssetReading: Hashable, Sendable {
    public var id: String
    public var fileName: String?
    public var captureDate: Date?
    public var keywords: [String]

    public init(id: String, fileName: String?, captureDate: Date?, keywords: [String] = []) {
        self.id = id
        self.fileName = fileName
        self.captureDate = captureDate
        self.keywords = keywords
    }
}

/// What happened in the photo library since a change token.
public nonisolated struct PhotosLibraryChanges: Sendable {
    /// Assets added or modified, to read again.
    public var upserted: Set<String>
    public var deleted: Set<String>
    /// The token these changes lead to, archived.
    public var token: Data

    public init(upserted: Set<String>, deleted: Set<String>, token: Data) {
        self.upserted = upserted
        self.deleted = deleted
        self.token = token
    }
}

/// The photo library as the index sees it: PhotoKit in the app (`PhotoKitIndexLibrary`), a fake in tests.
/// Every call may block; the indexer runs them off the main actor.
public nonisolated protocol PhotosIndexLibrary: Sendable {
    /// Every image of the library, newest first.
    func assetIDs() async -> [String]
    /// The images the library itself classifies as RAW, RAW + JPEG pairs included.
    func rawAssetIDs() async -> Set<String>
    /// Name, capture date and keywords of the given assets; those that no longer exist are left out.
    func readings(for ids: [String]) async -> [PhotosAssetReading]
    /// The current point in the library's change history, archived; nil when it can't be told.
    func currentChangeToken() async -> Data?
    /// Changes since `token`. Throws when the history no longer reaches back to it.
    func changes(since token: Data) async throws -> PhotosLibraryChanges
    /// Fires each time the library commits a change, from any app.
    func changeNotifications() -> AsyncStream<Void>
}

/// Brings the index of the Photos library up to date, in batches, off the main actor.
///
/// Two paths. With a change token from a previous pass, only what changed since is read again, including
/// what happened while the app was closed. Without one, the library is compared with the index and the
/// assets missing from it are read: a first build, or the rest of an interrupted one, since the token is
/// stored only when a pass reaches its end.
public nonisolated struct PhotosIndexer: Sendable {
    /// Measured on 74,000 photos: 0.4 ms per asset whatever the batch size; 1,000 gives two progress
    /// updates a second and one short write transaction each.
    public static let defaultBatchSize = 1000

    public nonisolated enum Mode: Sendable {
        case incremental
        case full
    }

    public nonisolated struct Outcome: Sendable, Equatable {
        public var mode: Mode
        /// Assets read from the library.
        public var read: Int
        public var deleted: Int
        /// False when the task was cancelled before the end; the next update picks up where this one stopped.
        public var isComplete: Bool
    }

    private let store: PhotosIndexStore
    private let library: any PhotosIndexLibrary
    private let batchSize: Int
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosIndexer")

    public init(store: PhotosIndexStore, library: any PhotosIndexLibrary, batchSize: Int = PhotosIndexer.defaultBatchSize) {
        self.store = store
        self.library = library
        self.batchSize = batchSize
    }

    /// Updates the index. `rawIDs` is the library's current RAW set; `progress` is told how far a pass
    /// longer than one batch is. Cancelling the task stops after the current batch.
    @discardableResult
    public func update(rawIDs: Set<String>, progress: @Sendable (IndexingProgress) async -> Void = { _ in }) async throws -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome: Outcome = if let changes = try await changesSinceLastPass() {
            try await apply(changes, rawIDs: rawIDs, progress: progress)
        } else {
            try await reconcile(rawIDs: rawIDs, progress: progress)
        }
        if outcome.isComplete {
            try await store.syncRAW(rawIDs)
        }
        if outcome.read > 0 || outcome.deleted > 0 || !outcome.isComplete {
            logger.notice("\(outcome.mode == .full ? "Full" : "Incremental", privacy: .public) pass: \(outcome.read) assets read, \(outcome.deleted) removed in \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)\(outcome.isComplete ? "" : ", interrupted", privacy: .public)")
        }
        return outcome
    }

    /// Nil when there is no usable history: no pass ever ended, or the library no longer remembers that far.
    /// In the second case the rows can't be trusted any more (changes were missed), so the index starts over.
    private func changesSinceLastPass() async throws -> PhotosLibraryChanges? {
        guard let token = try await store.changeToken() else { return nil }
        do {
            return try await library.changes(since: token)
        } catch {
            logger.notice("Change history unavailable, rebuilding the index: \(error.localizedDescription, privacy: .public)")
            try await store.reset()
            return nil
        }
    }

    private func apply(_ changes: PhotosLibraryChanges, rawIDs: Set<String>, progress: @Sendable (IndexingProgress) async -> Void) async throws -> Outcome {
        try await store.delete(ids: changes.deleted)
        let pending = changes.upserted.subtracting(changes.deleted).sorted()
        let report = pending.count > batchSize
        let isComplete = try await index(pending, rawIDs: rawIDs) { done in
            if report {
                await progress(IndexingProgress(done: done, total: pending.count))
            }
        }
        if isComplete {
            try await store.setChangeToken(changes.token)
        }
        return Outcome(mode: .incremental, read: pending.count, deleted: changes.deleted.count, isComplete: isComplete)
    }

    private func reconcile(rawIDs: Set<String>, progress: @Sendable (IndexingProgress) async -> Void) async throws -> Outcome {
        // Taken before listing: whatever changes during the pass is replayed by the next one.
        let token = await library.currentChangeToken()
        let present = await library.assetIDs()
        let indexed = try await store.assetIDs()
        let removed = indexed.subtracting(present)
        try await store.delete(ids: removed)

        // In library order, so the photos at the top of the grid come first.
        let pending = present.filter { !indexed.contains($0) }
        let alreadyDone = present.count - pending.count
        await progress(IndexingProgress(done: alreadyDone, total: present.count))
        let isComplete = try await index(pending, rawIDs: rawIDs) { done in
            await progress(IndexingProgress(done: alreadyDone + done, total: present.count))
        }
        if isComplete {
            try await store.setChangeToken(token)
        }
        return Outcome(mode: .full, read: pending.count, deleted: removed.count, isComplete: isComplete)
    }

    /// Reads and stores `ids` batch by batch, reporting how many are done. Returns false when cancelled
    /// before the last batch.
    private func index(_ ids: [String], rawIDs: Set<String>, report: (Int) async -> Void) async throws -> Bool {
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            if Task.isCancelled {
                return false
            }
            let batch = Array(ids[start ..< min(start + batchSize, ids.count)])
            let readings = await library.readings(for: batch)
            let entries = readings.map {
                PhotosAssetEntry(id: $0.id, fileName: $0.fileName, captureDate: $0.captureDate, isRAW: rawIDs.contains($0.id))
            }
            let keywords = Dictionary(readings.lazy.filter { !$0.keywords.isEmpty }.map { ($0.id, $0.keywords) }) { first, _ in first }
            do {
                try await store.save(entries, keywords: keywords)
            } catch is CancellationError {
                // The database refuses to write in a cancelled task: the batch is read again next time.
                return false
            }
            await report(start + batch.count)
        }
        return true
    }
}
