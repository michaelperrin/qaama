import Foundation
@testable import LibraryKit
import Testing

struct LibraryQueryTests {
    private func asset(_ id: String, rating: Int = 0, flag: ItemFlag = .none, edited: Bool = false, favorite: Bool = false,
                       keywords: [String] = [], date: TimeInterval = 0) -> LibraryAsset
    {
        LibraryAsset(id: id, pixelWidth: 1, pixelHeight: 1, creationDate: Date(timeIntervalSince1970: date), isFavorite: favorite,
                     rating: rating, flag: flag, keywords: keywords, hasEdit: edited)
    }

    @Test func defaultQueryIsUnfilteredAndNewestFirst() {
        let query = LibraryQuery()
        #expect(query.isUnfiltered)
        let old = asset("old", date: 1), new = asset("new", date: 2)
        #expect([old, new].sorted(by: query.areInIncreasingOrder).map(\.id) == ["new", "old"])
    }

    @Test func filtersInMemory() {
        var query = LibraryQuery()
        query.minimumRating = 3
        #expect(query.matches(asset("a", rating: 3)) && !query.matches(asset("b", rating: 2)))
        query = LibraryQuery()
        query.flag = .notRejected
        #expect(query.matches(asset("a")) && !query.matches(asset("b", flag: .rejected)))
        query = LibraryQuery()
        query.editedOnly = true
        #expect(!query.matches(asset("a")) && query.matches(asset("b", edited: true)))
        query = LibraryQuery()
        query.searchText = "LAPL"
        #expect(query.matches(asset("a", keywords: ["Lapland"])) && !query.matches(asset("b", keywords: ["sea"])))
        #expect(!query.isUnfiltered)
    }

    @Test func catalogStatementReflectsTheQuery() async throws {
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Q")
        try await store.save(folder)
        var a = CatalogItem(folderID: folder.id, relativePath: "b-sky.jpg", fileType: "public.jpeg", fileSize: 1, contentModified: Date(timeIntervalSince1970: 10), isRAW: true)
        a.rating = 4; a.flag = .picked; a.hasEdit = true; a.keywords = ["sky"]; a.captureDate = Date(timeIntervalSince1970: 10)
        var b = CatalogItem(folderID: folder.id, relativePath: "a-sea.jpg", fileType: "public.jpeg", fileSize: 1, contentModified: Date(timeIntervalSince1970: 20))
        b.rating = 1; b.flag = .rejected; b.captureDate = Date(timeIntervalSince1970: 20)
        try await store.save([a, b])

        var query = LibraryQuery()
        #expect(try await store.items(inFolder: folder.id, query: query).map(\.fileName) == ["a-sea.jpg", "b-sky.jpg"])
        query.ascending = true
        #expect(try await store.items(inFolder: folder.id, query: query).map(\.fileName) == ["b-sky.jpg", "a-sea.jpg"])
        query = LibraryQuery(); query.sort = .fileName; query.ascending = true
        #expect(try await store.items(inFolder: folder.id, query: query).map(\.fileName) == ["a-sea.jpg", "b-sky.jpg"])
        query = LibraryQuery(); query.sort = .rating
        #expect(try await store.items(inFolder: folder.id, query: query).first?.fileName == "b-sky.jpg")
        query = LibraryQuery(); query.minimumRating = 2
        #expect(try await store.items(inFolder: folder.id, query: query).map(\.fileName) == ["b-sky.jpg"])
        query = LibraryQuery(); query.flag = .notRejected
        #expect(try await store.items(inFolder: folder.id, query: query).map(\.fileName) == ["b-sky.jpg"])
        query = LibraryQuery(); query.editedOnly = true; query.rawOnly = true
        #expect(try await store.items(inFolder: folder.id, query: query).count == 1)
        query = LibraryQuery(); query.searchText = "sea"
        #expect(try await store.items(inFolder: folder.id, query: query).map(\.fileName) == ["a-sea.jpg"])
        query = LibraryQuery(); query.searchText = "sk"
        #expect(try await store.items(inFolder: folder.id, query: query).map(\.fileName) == ["b-sky.jpg"])
    }
}
