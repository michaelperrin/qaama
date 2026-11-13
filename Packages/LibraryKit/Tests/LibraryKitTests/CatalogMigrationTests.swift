import Foundation
import GRDB
import ImageIOKit
@testable import LibraryKit
import Testing

struct CatalogMigrationTests {
    /// A catalog as the version before folder search by substring left it, with one file in it.
    private func catalogBeforeFolderSearch() throws -> (DatabaseQueue, UUID) {
        let queue = try DatabaseQueue()
        try CatalogSchema.migrator.migrate(queue, upTo: "v3-photos-search")
        let folderID = UUID(), itemID = UUID()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO folder (id, bookmark, displayName) VALUES (?, ?, ?)", arguments: [folderID, Data([1]), "Trip"])
            try db.execute(sql: """
            INSERT INTO item (id, folderID, relativePath, fileName, fileType, fileSize, contentModified, keywords)
            VALUES (?, ?, 'Écosse/DSCF1234.RAF', 'DSCF1234.RAF', 'com.fuji.raw-image', 1, ?, '["Été","Highlands"]')
            """, arguments: [itemID, folderID, Date(timeIntervalSince1970: 10)])
        }
        return (queue, itemID)
    }

    @Test func folderSearchMigrationFoldsExistingItems() throws {
        let (queue, itemID) = try catalogBeforeFolderSearch()
        try CatalogSchema.migrator.migrate(queue)

        try queue.read { db in
            let item = try #require(try CatalogItem.fetchOne(db, key: itemID))
            #expect(item.foldedName == "dscf1234.raf")
            #expect(item.foldedKeywords == "ete\nhighlands")
            #expect(item.keywords == ["Été", "Highlands"])
            // The full-text table and the triggers that fed it are gone.
            #expect(try !db.tableExists("item_fts"))
            #expect(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'item'").isEmpty)
        }
    }

    @Test func captureDateOverrideMigrationKeepsItemsAndStartsWithoutCorrections() throws {
        let queue = try DatabaseQueue()
        try CatalogSchema.migrator.migrate(queue, upTo: "v4-folder-search")
        let folderID = UUID(), itemID = UUID()
        let shot = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO folder (id, bookmark, displayName) VALUES (?, ?, ?)", arguments: [folderID, Data([1]), "Trip"])
            try db.execute(sql: """
            INSERT INTO item (id, folderID, relativePath, fileName, fileType, fileSize, contentModified, captureDate)
            VALUES (?, ?, 'DSCF1234.RAF', 'DSCF1234.RAF', 'com.fuji.raw-image', 1, ?, ?)
            """, arguments: [itemID, folderID, Date(timeIntervalSince1970: 10), shot])
        }
        try CatalogSchema.migrator.migrate(queue)

        try queue.write { db in
            var item = try #require(try CatalogItem.fetchOne(db, key: itemID))
            #expect(item.captureDate == shot && item.captureDateOverride == nil && item.effectiveCaptureDate == shot)
            item.captureDateOverride = shot.addingTimeInterval(3600)
            try item.save(db)
            let reloaded = try #require(try CatalogItem.fetchOne(db, key: itemID))
            #expect(reloaded.effectiveCaptureDate == shot.addingTimeInterval(3600) && reloaded.captureDate == shot)
        }
    }

    @Test func locationMigrationStartsThePhotosIndexOver() throws {
        let queue = try DatabaseQueue()
        try CatalogSchema.migrator.migrate(queue, upTo: "v5-capture-date-override")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO photosAsset (id, fileName, nameStem, foldedName) VALUES ('a', 'a.jpg', 'a', 'a.jpg')")
            try db.execute(sql: "INSERT INTO photosAssetKeyword (assetID, keyword, folded) VALUES ('a', 'Été', 'ete')")
            try db.execute(sql: "INSERT INTO photosIndexState (id, changeToken) VALUES (1, ?)", arguments: [Data([1])])
        }
        try CatalogSchema.migrator.migrate(queue)

        try queue.write { db in
            // No row knows its position yet: without a token, the next pass reads the whole library again.
            #expect(try PhotosAssetEntry.fetchCount(db) == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photosAssetKeyword") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photosIndexState") == 0)
            try PhotosAssetEntry(id: "a", fileName: "a.jpg", captureDate: nil, isRAW: false,
                                 location: GeoCoordinate(latitude: 48.8566, longitude: 2.3522)).save(db)
            #expect(try PhotosAssetEntry.fetchOne(db, key: "a")?.location?.longitude == 2.3522)
        }
    }

    @Test func itemsStaySearchableAndWritableAfterTheMigration() throws {
        let (queue, itemID) = try catalogBeforeFolderSearch()
        try CatalogSchema.migrator.migrate(queue)

        try queue.write { db in
            var item = try #require(try CatalogItem.fetchOne(db, key: itemID))
            item.keywords.append("Glencoe")
            try item.save(db)
            let found = try String.fetchAll(db, sql: "SELECT fileName FROM item WHERE foldedKeywords LIKE '%glen%' AND foldedName LIKE '%1234%'")
            #expect(found == ["DSCF1234.RAF"])
        }
    }
}
