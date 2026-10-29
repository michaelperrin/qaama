import Foundation
@testable import LibraryKit
import Testing

struct CatalogStoreTests {
    private func makeStore() throws -> (CatalogStore, CatalogFolder) {
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data([1, 2, 3]), displayName: "Lapland")
        return (store, folder)
    }

    private func item(in folder: CatalogFolder, path: String, captureDate: Date? = nil, fileIdentifier: Data? = nil) -> CatalogItem {
        var item = CatalogItem(folderID: folder.id, relativePath: path, fileType: "public.jpeg", fileSize: 1234,
                               contentModified: Date(timeIntervalSince1970: 1000), fileIdentifier: fileIdentifier)
        item.captureDate = captureDate
        return item
    }

    @Test func savesAndListsFoldersAndItems() async throws {
        let (store, folder) = try makeStore()
        try await store.save(folder)
        try await store.save([
            item(in: folder, path: "old.jpg", captureDate: Date(timeIntervalSince1970: 100)),
            item(in: folder, path: "new.jpg", captureDate: Date(timeIntervalSince1970: 200)),
            item(in: folder, path: "undated.jpg"),
        ])

        let folders = try await store.folders()
        #expect(folders.map(\.displayName) == ["Lapland"])

        let items = try await store.items(inFolder: folder.id)
        #expect(items.map(\.fileName) == ["new.jpg", "old.jpg", "undated.jpg"])
        #expect(items.allSatisfy(\.needsMetadata))
    }

    @Test func findsItemsByPathIdentifierAndFingerprint() async throws {
        let (store, folder) = try makeStore()
        try await store.save(folder)
        var saved = item(in: folder, path: "Trip/DSCF0001.RAF", fileIdentifier: Data([9, 9]))
        saved.fingerprint = "abc"
        try await store.save(saved)

        #expect(try await store.item(inFolder: folder.id, relativePath: "Trip/DSCF0001.RAF")?.id == saved.id)
        #expect(try await store.item(fileIdentifier: Data([9, 9]))?.id == saved.id)
        #expect(try await store.item(fingerprint: "abc")?.id == saved.id)
        #expect(try await store.item(inFolder: folder.id, relativePath: "nope") == nil)
    }

    @Test func reconcileMarksMissingAndRestores() async throws {
        let (store, folder) = try makeStore()
        try await store.save(folder)
        let kept = item(in: folder, path: "kept.jpg")
        let gone = item(in: folder, path: "gone.jpg")
        try await store.save([kept, gone])

        let now = Date(timeIntervalSince1970: 5000)
        let newlyMissing = try await store.reconcile(folderID: folder.id, presentIDs: [kept.id], now: now)
        #expect(newlyMissing == [gone.id])
        #expect(try await store.items(inFolder: folder.id).map(\.id) == [kept.id])
        #expect(try await store.items(inFolder: folder.id, includeMissing: true).count == 2)

        // The file comes back: same identity, flag cleared.
        _ = try await store.reconcile(folderID: folder.id, presentIDs: [kept.id, gone.id], now: now)
        #expect(try await store.item(id: gone.id)?.isMissing == false)

        // Gone for good: purged after the retention period.
        _ = try await store.reconcile(folderID: folder.id, presentIDs: [kept.id], now: now)
        let purged = try await store.purgeMissing(olderThan: 10, now: now.addingTimeInterval(60))
        #expect(purged == 1)
        #expect(try await store.item(id: gone.id) == nil)
    }

    @Test func deletingAFolderDeletesItsItems() async throws {
        let (store, folder) = try makeStore()
        try await store.save(folder)
        try await store.save(item(in: folder, path: "a.jpg"))

        try await store.deleteFolder(id: folder.id)
        #expect(try await store.items(inFolder: folder.id, includeMissing: true).isEmpty)
    }

    @Test func metadataBatchesAndUserDecisionsRoundTrip() async throws {
        let (store, folder) = try makeStore()
        try await store.save(folder)
        var photo = item(in: folder, path: "a.jpg")
        try await store.save(photo)
        #expect(try await store.itemsNeedingMetadata(inFolder: folder.id, limit: 10).count == 1)

        photo.pixelWidth = 6000
        photo.pixelHeight = 4000
        photo.metadataRead = Date(timeIntervalSince1970: 2000)
        photo.rating = 4
        photo.flag = .picked
        photo.keywords = ["lapland", "winter"]
        try await store.save(photo)

        #expect(try await store.itemsNeedingMetadata(inFolder: folder.id, limit: 10).isEmpty)
        let reloaded = try #require(try await store.item(id: photo.id))
        #expect(reloaded.rating == 4 && reloaded.flag == .picked && reloaded.keywords == ["lapland", "winter"])
        #expect(reloaded.pixelWidth == 6000)
    }

    @Test func searchesFileNamesAndKeywords() async throws {
        let (store, folder) = try makeStore()
        try await store.save(folder)
        var aurora = item(in: folder, path: "DSCF0001.RAF")
        aurora.keywords = ["aurora", "night"]
        var road = item(in: folder, path: "road-trip.jpg")
        try await store.save([aurora, road])

        #expect(try await store.search("auro").map(\.id) == [aurora.id])
        #expect(try await store.search("road").map(\.id) == [road.id])
        #expect(try await store.search("DSCF").map(\.id) == [aurora.id])
        #expect(try await store.search("zzz").isEmpty)
        road.keywords = ["aurora"]
        try await store.save(road)
        #expect(try await store.search("aurora").count == 2)
    }

    @Test func observesChanges() async throws {
        let (store, folder) = try makeStore()
        try await store.save(folder)
        var iterator = store.observeItems(inFolder: folder.id).makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        try await store.save(item(in: folder, path: "a.jpg"))
        let afterInsert = try await iterator.next()
        #expect(afterInsert?.count == 1)
    }
}
