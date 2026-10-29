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
        return migrator
    }
}
