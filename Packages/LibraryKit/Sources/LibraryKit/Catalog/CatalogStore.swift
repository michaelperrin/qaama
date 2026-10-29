import Foundation
import GRDB
import OSLog

/// The local index of folders and image files: SQLite through GRDB, behind an API expressed in
/// catalog terms so the rest of the code never sees the database.
///
/// The catalog is a cache of what the folders and sidecars say (`docs/catalogue.md`): it can be
/// deleted and rebuilt. Thread-safe; calls can come from any actor.
public final nonisolated class CatalogStore: Sendable {
    private let writer: any DatabaseWriter
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "CatalogStore")

    /// Opens (or creates) the catalog at `url`, applying pending migrations.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        writer = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
        try CatalogSchema.migrator.migrate(writer)
    }

    /// Catalog in memory, for tests and previews.
    public static func inMemory() throws -> CatalogStore {
        try CatalogStore(writer: DatabaseQueue())
    }

    /// Default location in the app's Application Support folder.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("catalog.sqlite")
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try CatalogSchema.migrator.migrate(writer)
    }

    // MARK: - Folders

    public func folders() async throws -> [CatalogFolder] {
        try await writer.read { db in
            try CatalogFolder.order(Column("displayName")).fetchAll(db)
        }
    }

    public func save(_ folder: CatalogFolder) async throws {
        try await writer.write { db in try folder.save(db) }
    }

    /// Removes the folder and, through the schema, every item in it.
    public func deleteFolder(id: UUID) async throws {
        _ = try await writer.write { db in try CatalogFolder.deleteOne(db, key: id) }
    }

    // MARK: - Items

    public func item(id: UUID) async throws -> CatalogItem? {
        try await writer.read { db in try CatalogItem.fetchOne(db, key: id) }
    }

    /// Items of a folder, newest capture first (files without a capture date last).
    public func items(inFolder folderID: UUID, includeMissing: Bool = false) async throws -> [CatalogItem] {
        try await writer.read { db in
            var request = CatalogItem.filter(CatalogItem.Col.folderID == folderID)
            if !includeMissing {
                request = request.filter(CatalogItem.Col.isMissing == false)
            }
            return try request
                .order(CatalogItem.Col.captureDate.desc, CatalogItem.Col.contentModified.desc)
                .fetchAll(db)
        }
    }

    public func save(_ item: CatalogItem) async throws {
        try await writer.write { db in try item.save(db) }
    }

    /// Inserts or updates many items in one transaction.
    public func save(_ items: [CatalogItem]) async throws {
        try await writer.write { db in
            for item in items {
                try item.save(db)
            }
        }
    }

    public func deleteItem(id: UUID) async throws {
        _ = try await writer.write { db in try CatalogItem.deleteOne(db, key: id) }
    }

    // MARK: - Identity lookups (docs/catalogue.md §3)

    public func item(inFolder folderID: UUID, relativePath: String) async throws -> CatalogItem? {
        try await writer.read { db in
            try CatalogItem
                .filter(CatalogItem.Col.folderID == folderID && CatalogItem.Col.relativePath == relativePath)
                .fetchOne(db)
        }
    }

    public func item(fileIdentifier: Data) async throws -> CatalogItem? {
        try await writer.read { db in
            try CatalogItem.filter(CatalogItem.Col.fileIdentifier == fileIdentifier).fetchOne(db)
        }
    }

    public func item(fingerprint: String) async throws -> CatalogItem? {
        try await writer.read { db in
            try CatalogItem.filter(CatalogItem.Col.fingerprint == fingerprint).fetchOne(db)
        }
    }

    /// Marks as missing every item of the folder whose id is not in `presentIDs`, and clears the
    /// flag on those that are. Returns the ids newly marked missing.
    public func reconcile(folderID: UUID, presentIDs: Set<UUID>, now: Date = .now) async throws -> [UUID] {
        try await writer.write { db in
            let all = try CatalogItem.filter(CatalogItem.Col.folderID == folderID).fetchAll(db)
            var newlyMissing: [UUID] = []
            for var item in all {
                let present = presentIDs.contains(item.id)
                if present, item.isMissing {
                    item.isMissing = false
                    item.missingSince = nil
                    try item.update(db)
                } else if !present, !item.isMissing {
                    item.isMissing = true
                    item.missingSince = now
                    try item.update(db)
                    newlyMissing.append(item.id)
                }
            }
            return newlyMissing
        }
    }

    /// Deletes items missing for longer than `retention`.
    public func purgeMissing(olderThan retention: TimeInterval = 30 * 24 * 3600, now: Date = .now) async throws -> Int {
        try await writer.write { db in
            try CatalogItem
                .filter(CatalogItem.Col.isMissing == true)
                .filter(Column("missingSince") < now.addingTimeInterval(-retention))
                .deleteAll(db)
        }
    }

    // MARK: - Metadata phase

    /// Items whose header still has to be read; `limit` bounds a batch. Items in `preferring` (those on
    /// screen, typically) come first, then the rest in path order.
    public func itemsNeedingMetadata(inFolder folderID: UUID, limit: Int, preferring preferred: Set<UUID> = []) async throws -> [CatalogItem] {
        try await writer.read { db in
            let pending = CatalogItem
                .filter(CatalogItem.Col.folderID == folderID && CatalogItem.Col.isMissing == false)
                .filter(CatalogItem.Col.metadataRead == nil || CatalogItem.Col.metadataRead < CatalogItem.Col.contentModified)
            var batch: [CatalogItem] = []
            if !preferred.isEmpty {
                batch = try pending.filter(preferred.contains(CatalogItem.Col.id)).limit(limit).fetchAll(db)
            }
            if batch.count < limit {
                let taken = Set(batch.map(\.id))
                let rest = try pending
                    .filter(!taken.contains(CatalogItem.Col.id))
                    .order(CatalogItem.Col.relativePath)
                    .limit(limit - batch.count)
                    .fetchAll(db)
                batch += rest
            }
            return batch
        }
    }

    // MARK: - Search

    /// Full-text search on file names and keywords, within one folder or across all.
    public func search(_ text: String, inFolder folderID: UUID? = nil) async throws -> [CatalogItem] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try await writer.read { db in
            // The FTS table mirrors `item` row by row (synchronized at creation), so rowids match.
            var sql = """
            SELECT item.* FROM item
            JOIN item_fts ON item_fts.rowid = item.rowid
            WHERE item_fts MATCH ?
            """
            var arguments: StatementArguments = [pattern]
            if let folderID {
                sql += " AND item.folderID = ?"
                arguments += [folderID]
            }
            return try CatalogItem.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    // MARK: - Observation

    /// Emits the items of a folder (current first, then after every change) until the consumer stops.
    public func observeItems(inFolder folderID: UUID) -> AsyncThrowingStream<[CatalogItem], Error> {
        let observation = ValueObservation.tracking { db in
            try CatalogItem
                .filter(CatalogItem.Col.folderID == folderID && CatalogItem.Col.isMissing == false)
                .order(CatalogItem.Col.captureDate.desc, CatalogItem.Col.contentModified.desc)
                .fetchAll(db)
        }
        let writer = writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await items in observation.values(in: writer) {
                        continuation.yield(items)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
