import Foundation
import GRDB

/// Numbered migrations of the catalog database. Never edit a registered migration: add a new one.
nonisolated enum CatalogSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Development only: a changed migration recreates the database instead of failing.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1-folders-and-items") { db in
            try db.create(table: "folder") { t in
                t.primaryKey("id", .blob)
                t.column("bookmark", .blob).notNull()
                t.column("displayName", .text).notNull()
                t.column("lastScan", .datetime)
            }

            try db.create(table: "item") { t in
                t.primaryKey("id", .blob)
                t.belongsTo("folder", onDelete: .cascade).notNull()
                t.column("relativePath", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("fileType", .text).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("contentModified", .datetime).notNull()
                t.column("fileIdentifier", .blob)
                t.column("fingerprint", .text)
                t.column("isMissing", .boolean).notNull().defaults(to: false)
                t.column("missingSince", .datetime)

                t.column("pixelWidth", .integer)
                t.column("pixelHeight", .integer)
                t.column("orientation", .integer)
                t.column("captureDate", .datetime)
                t.column("cameraMake", .text)
                t.column("cameraModel", .text)
                t.column("lens", .text)
                t.column("iso", .integer)
                t.column("exposureTime", .double)
                t.column("aperture", .double)
                t.column("focalLength", .double)
                t.column("isRAW", .boolean).notNull().defaults(to: false)
                t.column("metadataRead", .datetime)

                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("flag", .integer).notNull().defaults(to: 0)
                t.column("keywords", .text).notNull().defaults(to: "[]")
                t.column("hasEdit", .boolean).notNull().defaults(to: false)
                t.column("sidecarModified", .datetime)

                t.column("pairedItemID", .blob)

                t.uniqueKey(["folderID", "relativePath"])
            }
            try db.create(index: "item_fileIdentifier", on: "item", columns: ["fileIdentifier"])
            try db.create(index: "item_fingerprint", on: "item", columns: ["fingerprint"])
            try db.create(index: "item_captureDate", on: "item", columns: ["captureDate"])
            try db.create(index: "item_rating", on: "item", columns: ["rating"])
            try db.create(index: "item_flag", on: "item", columns: ["flag"])

            // Full-text search on file names and keywords, kept in sync by triggers.
            try db.create(virtualTable: "item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .unicode61()
                t.column("fileName")
                t.column("keywords")
            }
        }

        migrator.registerMigration("v2-photos-index") { db in
            // Index of the Apple Photos library (docs/catalogue.md §10): what PhotoKit can't query, one row
            // per asset under its local identifier. Derived data only, rebuilt from the library at any time.
            try db.create(table: "photosAsset") { t in
                t.primaryKey("id", .text)
                t.column("fileName", .text)
                t.column("nameStem", .text).notNull()
                t.column("captureSecond", .integer)
                t.column("isRAW", .boolean).notNull().defaults(to: false)
            }
            // Pairing a RAW with its JPEG twin joins on name and capture time, starting from the RAW rows.
            try db.create(index: "photosAsset_pair", on: "photosAsset", columns: ["nameStem", "captureSecond"])
            try db.create(index: "photosAsset_isRAW", on: "photosAsset", columns: ["isRAW"])

            try db.create(table: "photosIndexState") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("changeToken", .blob)
            }
        }

        migrator.registerMigration("v3-photos-search") { db in
            // Search needs the keywords and a folded name of every asset, read in the same pass as the
            // rest: the index starts over and is rebuilt in the background (half a minute for 74,000 photos).
            try db.execute(sql: "DELETE FROM photosAsset")
            try db.execute(sql: "DELETE FROM photosIndexState")
            try db.alter(table: "photosAsset") { t in
                t.add(column: "foldedName", .text).notNull().defaults(to: "")
            }
            // One row per asset and keyword rather than a list in a column of `photosAsset`: several
            // values per photo, their own table (docs/catalogue.md §10).
            try db.create(table: "photosAssetKeyword", options: .withoutRowID) { t in
                t.column("assetID", .text).notNull().references("photosAsset", onDelete: .cascade)
                t.column("keyword", .text).notNull()
                t.column("folded", .text).notNull()
                t.primaryKey(["assetID", "keyword"])
            }
        }

        migrator.registerMigration("v4-folder-search") { db in
            // Folders are searched like Photos (`SearchText`): by any part of a name, without case or
            // accents. Folded copies and LIKE replace the full-text index, which only matched the start
            // of words ("1234" didn't find DSCF1234.RAF).
            try db.dropFTS5SynchronizationTriggers(forTable: "item_fts")
            try db.drop(table: "item_fts")
            try db.alter(table: "item") { t in
                t.add(column: "foldedName", .text).notNull().defaults(to: "")
                t.add(column: "foldedKeywords", .text).notNull().defaults(to: "")
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, fileName, keywords FROM item") {
                let id: DatabaseValue = row["id"]
                let fileName: String = row["fileName"]
                let keywordsJSON: String = row["keywords"]
                let keywords = (try? JSONDecoder().decode([String].self, from: Data(keywordsJSON.utf8))) ?? []
                try db.execute(sql: "UPDATE item SET foldedName = ?, foldedKeywords = ? WHERE id = ?",
                               arguments: [SearchText.fold(fileName), SearchText.foldedList(keywords), id])
            }
        }

        migrator.registerMigration("v5-capture-date-override") { db in
            // The capture date the user corrected, mirrored from the sidecar like the other decisions;
            // `captureDate` stays what the header says, so removing the correction needs no re-read.
            try db.alter(table: "item") { t in
                t.add(column: "captureDateOverride", .datetime)
            }
        }

        migrator.registerMigration("v6-photos-location") { db in
            // The map needs where every photo was taken. Read with the name in the same pass and stale
            // with it, hence columns of `photosAsset` rather than a table of their own; the index starts
            // over to fill them (half a minute in the background for 74,000 photos).
            // Foreign keys are off during a migration: the keywords don't go with their asset by themselves.
            try db.execute(sql: "DELETE FROM photosAssetKeyword")
            try db.execute(sql: "DELETE FROM photosAsset")
            try db.execute(sql: "DELETE FROM photosIndexState")
            try db.alter(table: "photosAsset") { t in
                t.add(column: "latitude", .double)
                t.add(column: "longitude", .double)
            }
        }

        migrator.registerMigration("v7-folder-location") { db in
            // Where a folder's photos were taken, for the map: in the header, read with the rest of
            // it and stale with it, hence columns of `item`. Headers read before are read again in
            // the background the next time their folder is opened.
            try db.alter(table: "item") { t in
                t.add(column: "latitude", .double)
                t.add(column: "longitude", .double)
            }
            try db.execute(sql: "UPDATE item SET metadataRead = NULL")
        }
        return migrator
    }
}
