import Foundation
import Observation
import OSLog

/// What the Photos sources read from the index at listing time. A value, so the rows of a lazy
/// collection can capture it.
public nonisolated struct PhotosIndexSnapshot: Hashable, Sendable {
    /// The assets the library classifies as RAW, RAW + JPEG pairs included.
    public var rawIDs: Set<String> = []
    /// For a RAW + JPEG pair stored as two assets, each half's identifier to the other's.
    public var pairedIDs: [String: String] = [:]
    /// The JPEG halves of those pairs, hidden from listings unless asked for.
    public var twinIDs: Set<String> = []

    public init() {}

    init(rawIDs: Set<String>, pairs: [PhotosAssetPair]) {
        self.rawIDs = rawIDs
        for pair in pairs {
            pairedIDs[pair.rawID] = pair.twinID
            pairedIDs[pair.twinID] = pair.rawID
            twinIDs.insert(pair.twinID)
        }
    }
}

/// The local index of the Apple Photos library, shared by the library source and the album sources:
/// what PhotoKit can't filter on, kept current in the background.
///
/// The RAW set comes straight from the library (its RAW smart album), at the start of every pass: it is
/// current a fraction of a second after `start()`, whatever the state of the index. The rest (file
/// names, hence the RAW + JPEG pairs stored as two assets) is read by `PhotosIndexer` into the catalog;
/// `progress` tells how far that is.
@Observable
public final class PhotosIndex {
    /// Current answers; listings built from an older value are refreshed by their source.
    public private(set) var snapshot = PhotosIndexSnapshot()
    /// Set while a pass long enough to matter is running.
    public private(set) var progress: IndexingProgress?
    /// Bumped when a pass changed what `search` and `locatedAssets` read (names, keywords, positions):
    /// searches and maps in use are run again.
    public private(set) var contentVersion = 0

    /// Names come from PhotoKit's own database at the same speed whatever the priority (0.4 ms per
    /// asset measured at both), so the pass leaves the performance cores to the grid.
    private static let indexingPriority = TaskPriority.utility

    private let store: PhotosIndexStore
    private let library: any PhotosIndexLibrary
    /// Photos commits changes in bursts (imports, iCloud sync); one pass after they settle is enough.
    private let settleDelay: Duration
    private var isStarted = false
    private var pass: Task<Void, Never>?
    private var passRequested = false
    private var notifications: Task<Void, Never>?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosIndex")

    public init(store: PhotosIndexStore, library: any PhotosIndexLibrary, settleDelay: Duration = .seconds(1)) {
        self.store = store
        self.library = library
        self.settleDelay = settleDelay
    }

    isolated deinit {
        notifications?.cancel()
        pass?.cancel()
    }

    /// Loads what the last pass left in the catalog (34 ms measured, where asking the library first took
    /// 190 to 250 ms before the first listing), then updates the index in the background and follows the
    /// library's changes. Call once access to Photos is granted; calling it again is a no-op.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await refreshSnapshot(rawIDs: store.rawIDs())
        } catch {
            logger.error("Couldn't read the index: \(error.localizedDescription, privacy: .public)")
        }
        logger.notice("Loaded \(self.snapshot.rawIDs.count) RAW and \(self.snapshot.twinIDs.count) separate JPEG twins from the catalog in \((clock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")

        let changes = library.changeNotifications()
        notifications = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                update(after: settleDelay)
            }
        }
        update()
    }

    /// The assets whose file name or keywords hold every word of `text` (see `PhotosIndexStore.search`),
    /// among those indexed so far; nil when `text` has no word.
    public func search(_ text: String) async throws -> [String]? {
        try await store.search(text)
    }

    /// The assets indexed so far that have a position (see `PhotosIndexStore.locatedAssets`).
    public func locatedAssets() async throws -> [LocatedAsset] {
        try await store.locatedAssets()
    }

    /// Runs a pass, or asks for one more when one is already running: the library changed meanwhile.
    func update(after delay: Duration = .zero) {
        guard pass == nil else {
            passRequested = true
            return
        }
        pass = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.runPass()
            guard let self else { return }
            pass = nil
            if passRequested {
                passRequested = false
                update(after: settleDelay)
            }
        }
    }

    /// Waits for the passes in flight; for tests.
    func waitUntilIdle() async {
        while let pass {
            await pass.value
        }
    }

    private func runPass() async {
        let rawIDs = await Task.detached(priority: .userInitiated) { [library] in await library.rawAssetIDs() }.value
        // The RAW filter and badges don't wait for the rest of the pass.
        await refreshSnapshot(rawIDs: rawIDs)
        let indexer = PhotosIndexer(store: store, library: library)
        let report: @Sendable (IndexingProgress) async -> Void = { [weak self] progress in
            await self?.report(progress)
        }
        let work = Task.detached(priority: Self.indexingPriority) {
            try await indexer.update(rawIDs: rawIDs, progress: report)
        }
        var contentChanged = false
        do {
            // A detached task doesn't follow its awaiter's cancellation by itself.
            let outcome = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            contentChanged = outcome.read > 0 || outcome.deleted > 0
            if !outcome.isComplete {
                logger.notice("Indexing interrupted; it resumes at the next launch")
            }
        } catch is CancellationError {
            logger.notice("Indexing interrupted; it resumes at the next launch")
        } catch {
            logger.error("Indexing failed: \(error.localizedDescription, privacy: .public)")
        }
        progress = nil
        await refreshSnapshot(rawIDs: rawIDs)
        if contentChanged {
            contentVersion += 1
        }
    }

    private func report(_ progress: IndexingProgress) {
        self.progress = progress.done < progress.total ? progress : nil
    }

    private func refreshSnapshot(rawIDs: Set<String>) async {
        var pairs: [PhotosAssetPair] = []
        do {
            pairs = try await store.separatePairs()
        } catch {
            logger.error("Couldn't read the RAW + JPEG pairs: \(error.localizedDescription, privacy: .public)")
        }
        let fresh = PhotosIndexSnapshot(rawIDs: rawIDs, pairs: pairs)
        // Assigning an equal value would still refetch every Photos source.
        if fresh != snapshot {
            snapshot = fresh
        }
    }
}
