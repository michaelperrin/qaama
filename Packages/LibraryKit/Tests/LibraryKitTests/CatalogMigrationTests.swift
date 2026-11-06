import Foundation
import GRDB
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
