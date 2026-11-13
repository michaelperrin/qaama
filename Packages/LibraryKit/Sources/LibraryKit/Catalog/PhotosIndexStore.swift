import Foundation
import GRDB
import ImageIOKit

/// What the index keeps about one asset of the Apple Photos library: the facts PhotoKit can't query.
public nonisolated struct PhotosAssetEntry: Codable, Hashable, Sendable, Identifiable {
    /// PhotoKit local identifier.
    public var id: String
    /// The name the photo was imported or shot under, extension included.
    public var fileName: String?
    /// `fileName` without its extension, lowercased; empty when the name is unknown. With
    /// `captureSecond`, what a RAW and its JPEG twin have in common.
    public var nameStem: String
    /// `fileName` as search compares it (`SearchText.fold`); empty when the name is unknown.
    public var foldedName: String
    /// Capture date in whole seconds since 1970.
    public var captureSecond: Int64?
    public var isRAW: Bool
    /// Where the photo was taken, in degrees; both nil when the library holds no position for it.
    public var latitude: Double?
    public var longitude: Double?

    public init(id: String, fileName: String?, captureDate: Date?, isRAW: Bool, location: GeoCoordinate? = nil) {
        self.id = id
        self.fileName = fileName
        nameStem = Self.stem(of: fileName)
        foldedName = SearchText.fold(fileName ?? "")
        captureSecond = captureDate.map { Int64($0.timeIntervalSince1970.rounded(.down)) }
        self.isRAW = isRAW
        latitude = location?.latitude
        longitude = location?.longitude
    }

    public var location: GeoCoordinate? {
        guard let latitude, let longitude else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    static func stem(of fileName: String?) -> String {
        guard let fileName else { return "" }
        return (fileName as NSString).deletingPathExtension.lowercased()
    }
}

nonisolated extension PhotosAssetEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "photosAsset"
}

/// A RAW and the JPEG shot with it, when Photos holds them as two assets instead of one.
public nonisolated struct PhotosAssetPair: Hashable, Sendable {
    public var rawID: String
    public var twinID: String
}

/// The Photos part of the catalog file: one row per asset of the library and one per keyword of an
/// asset, plus the point in the library's change history the rows are current with.
///
/// Derived from PhotoKit only (`docs/catalogue.md` §10): it can be deleted and rebuilt. Thread-safe.
public final nonisolated class PhotosIndexStore: Sendable {
    /// SQLite bounds the variables of a statement; identifier lists are bound in slices.
    private static let sliceSize = 500

    private let writer: any DatabaseWriter

    public init(catalog: CatalogStore) {
        writer = catalog.writer
    }

    // MARK: - Entries

    public func assetIDs() async throws -> Set<String> {
        try await writer.read { db in try String.fetchSet(db, sql: "SELECT id FROM photosAsset") }
    }

    public func count() async throws -> Int {
        try await writer.read { db in try PhotosAssetEntry.fetchCount(db) }
    }

    public func entry(id: String) async throws -> PhotosAssetEntry? {
        try await writer.read { db in try PhotosAssetEntry.fetchOne(db, key: id) }
    }

    /// Inserts or updates many entries in one transaction. `keywords`, by asset identifier, replaces the
    /// keywords of each entry saved: an entry without any there ends up with none.
    public func save(_ entries: [PhotosAssetEntry], keywords: [String: [String]] = [:]) async throws {
        guard !entries.isEmpty else { return }
        try await writer.write { db in
            let clear = try db.makeStatement(sql: "DELETE FROM photosAssetKeyword WHERE assetID = ?")
            let insert = try db.makeStatement(sql: "INSERT OR IGNORE INTO photosAssetKeyword (assetID, keyword, folded) VALUES (?, ?, ?)")
            for entry in entries {
                try entry.save(db)
                try clear.execute(arguments: [entry.id])
                for keyword in keywords[entry.id] ?? [] {
                    try insert.execute(arguments: [entry.id, keyword, SearchText.fold(keyword)])
                }
            }
        }
    }

    public func keywords(of id: String) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT keyword FROM photosAssetKeyword WHERE assetID = ? ORDER BY keyword", arguments: [id])
        }
    }

    public func delete(ids: some Collection<String> & Sendable) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { db in
            for slice in Self.slices(of: ids) {
                try PhotosAssetEntry.deleteAll(db, keys: slice)
            }
        }
    }

    /// Empties the index and forgets the change token: the next update rebuilds everything.
    public func reset() async throws {
        try await writer.write { db in
            try PhotosAssetEntry.deleteAll(db)
            try db.execute(sql: "DELETE FROM photosIndexState")
        }
    }

    // MARK: - RAW and pairs

    /// The RAW set as of the last pass: known without asking the library, so listings start with it.
    public func rawIDs() async throws -> Set<String> {
        try await writer.read { db in try String.fetchSet(db, sql: "SELECT id FROM photosAsset WHERE isRAW = 1") }
    }

    /// Makes `isRAW` true for exactly the indexed assets in `rawIDs`. The library decides what is a RAW
    /// (its RAW smart album) and can change its mind without the asset's row being read again.
    public func syncRAW(_ rawIDs: Set<String>) async throws {
        try await writer.write { db in
            let flagged = try String.fetchSet(db, sql: "SELECT id FROM photosAsset WHERE isRAW = 1")
            for (value, ids) in [(false, flagged.subtracting(rawIDs)), (true, rawIDs.subtracting(flagged))] {
                for slice in Self.slices(of: ids) {
                    try PhotosAssetEntry.filter(keys: slice).updateAll(db, Column("isRAW").set(to: value))
                }
            }
        }
    }

    /// RAW + JPEG pairs stored as two assets: same file name but for the extension, same capture second.
    public func separatePairs() async throws -> [PhotosAssetPair] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT raw.id AS rawID, twin.id AS twinID
            FROM photosAsset raw
            JOIN photosAsset twin ON twin.nameStem = raw.nameStem AND twin.captureSecond = raw.captureSecond
            WHERE raw.isRAW = 1 AND twin.isRAW = 0 AND raw.nameStem <> ''
            """)
            return rows.map { PhotosAssetPair(rawID: $0["rawID"], twinID: $0["twinID"]) }
        }
    }

    // MARK: - Search

    /// The assets whose file name or keywords hold every word of `text`, as substrings and whatever the
    /// case and accents: "1234 lapland" finds `DSCF1234.RAF` tagged "Lapland". Nil when `text` has no word.
    ///
    /// A scan of folded text rather than a full-text index (see `SearchText`): a pass over 74,000 short
    /// names takes a few milliseconds.
    public func search(_ text: String) async throws -> [String]? {
        let words = SearchText.words(in: text)
        guard !words.isEmpty else { return nil }
        var clauses: [String] = []
        var arguments = StatementArguments()
        for word in words {
            let pattern = SearchText.likePattern(containing: word)
            clauses.append("(foldedName LIKE ? ESCAPE '\\' OR id IN (SELECT assetID FROM photosAssetKeyword WHERE folded LIKE ? ESCAPE '\\'))")
            arguments += [pattern, pattern]
        }
        let sql = "SELECT id FROM photosAsset WHERE " + clauses.joined(separator: " AND ")
        return try await writer.read { [arguments] db in try String.fetchAll(db, sql: sql, arguments: arguments) }
    }

    // MARK: - Places

    /// Every indexed asset that has a position, for the map. One scan of the table: the map clusters
    /// them in memory (`PhotoMapIndex`), so nothing here depends on the region shown.
    public func locatedAssets() async throws -> [LocatedAsset] {
        try await writer.read { db in
            let rows = try Row.fetchCursor(db, sql: "SELECT id, latitude, longitude, captureSecond FROM photosAsset WHERE latitude IS NOT NULL AND longitude IS NOT NULL")
            var assets: [LocatedAsset] = []
            while let row = try rows.next() {
                let second: Int64? = row[3]
                assets.append(LocatedAsset(id: row[0], coordinate: GeoCoordinate(latitude: row[1], longitude: row[2]),
                                           captureDate: second.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
            }
            return assets
        }
    }

    // MARK: - Change history

    /// The library's change token the index is current with, archived; nil until a first full pass ended.
    public func changeToken() async throws -> Data? {
        try await writer.read { db in try Data.fetchOne(db, sql: "SELECT changeToken FROM photosIndexState WHERE id = 1") }
    }

    public func setChangeToken(_ token: Data?) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO photosIndexState (id, changeToken) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET changeToken = excluded.changeToken",
                           arguments: [token])
        }
    }

    private static func slices(of ids: some Collection<String>) -> [[String]] {
        let all = Array(ids)
        return stride(from: 0, to: all.count, by: sliceSize).map { Array(all[$0 ..< min($0 + sliceSize, all.count)]) }
    }
}
