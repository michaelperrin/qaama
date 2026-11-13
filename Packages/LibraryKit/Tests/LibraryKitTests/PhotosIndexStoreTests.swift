import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

struct PhotosIndexStoreTests {
    private func makeStore() throws -> PhotosIndexStore {
        try PhotosIndexStore(catalog: CatalogStore.inMemory())
    }

    private func entry(_ id: String, _ fileName: String?, at second: TimeInterval? = 100, isRAW: Bool = false) -> PhotosAssetEntry {
        PhotosAssetEntry(id: id, fileName: fileName, captureDate: second.map { Date(timeIntervalSince1970: $0) }, isRAW: isRAW)
    }

    @Test func derivesThePairingKeyFromNameAndDate() {
        let raw = PhotosAssetEntry(id: "a", fileName: "DSCF0001.RAF", captureDate: Date(timeIntervalSince1970: 100.9), isRAW: true)
        #expect(raw.nameStem == "dscf0001")
        #expect(raw.captureSecond == 100)
        #expect(PhotosAssetEntry.stem(of: "Holiday.2026.jpeg") == "holiday.2026")
        #expect(PhotosAssetEntry.stem(of: nil) == "")
    }

    @Test func savesUpdatesAndDeletesEntries() async throws {
        let store = try makeStore()
        try await store.save([entry("a", "one.jpg"), entry("b", "two.jpg")])
        try await store.save([entry("a", "renamed.jpg")])

        #expect(try await store.assetIDs() == ["a", "b"])
        #expect(try await store.entry(id: "a")?.fileName == "renamed.jpg")

        try await store.delete(ids: ["a", "missing"])
        #expect(try await store.assetIDs() == ["b"])
    }

    @Test func handlesIdentifierListsLongerThanOneStatement() async throws {
        let store = try makeStore()
        let ids = (0 ..< 1200).map { "asset-\($0)" }
        try await store.save(ids.map { entry($0, "\($0).jpg") })

        try await store.syncRAW(Set(ids.prefix(700)))
        #expect(try await store.entry(id: "asset-699")?.isRAW == true)
        #expect(try await store.entry(id: "asset-700")?.isRAW == false)

        try await store.delete(ids: Set(ids.prefix(1100)))
        #expect(try await store.count() == 100)
    }

    @Test func syncRAWFollowsTheLibrary() async throws {
        let store = try makeStore()
        try await store.save([entry("a", "a.raf", isRAW: true), entry("b", "b.jpg"), entry("c", "c.jpg")])

        // The library now says b is a RAW (a pair whose JPEG is the original) and a no longer is.
        try await store.syncRAW(["b", "not-indexed-yet"])
        #expect(try await store.entry(id: "a")?.isRAW == false)
        #expect(try await store.entry(id: "b")?.isRAW == true)
        #expect(try await store.entry(id: "c")?.isRAW == false)
    }

    @Test func pairsARAWWithTheJPEGShotAtTheSameSecond() async throws {
        let store = try makeStore()
        try await store.save([
            entry("raw", "IMG_0204.CR2", at: 100, isRAW: true),
            entry("twin", "img_0204.jpg", at: 100),
            // Same counter on another day: the camera wrapped around.
            entry("other-day", "IMG_0204.JPG", at: 900),
            entry("lonely-jpeg", "IMG_0300.JPG", at: 100),
            entry("lonely-raw", "IMG_0400.CR2", at: 100, isRAW: true),
            // Two RAW files never pair with each other.
            entry("raw-copy", "IMG_0204.DNG", at: 100, isRAW: true),
        ])

        let pairs = try await store.separatePairs()
        #expect(Set(pairs) == [PhotosAssetPair(rawID: "raw", twinID: "twin"), PhotosAssetPair(rawID: "raw-copy", twinID: "twin")])
    }

    @Test func neverPairsOnMissingNamesOrDates() async throws {
        let store = try makeStore()
        try await store.save([
            entry("nameless-raw", nil, at: 100, isRAW: true),
            entry("nameless-jpeg", nil, at: 100),
            entry("undated-raw", "IMG_1.CR2", at: nil, isRAW: true),
            entry("undated-jpeg", "IMG_1.JPG", at: nil),
        ])
        #expect(try await store.separatePairs().isEmpty)
    }

    @Test func replacesAndRemovesKeywordsWithTheirAsset() async throws {
        let store = try makeStore()
        try await store.save([entry("a", "a.jpg"), entry("b", "b.jpg")], keywords: ["a": ["Lapland", "Winter"], "b": ["Winter"]])
        #expect(try await store.keywords(of: "a") == ["Lapland", "Winter"])

        // Read again after the keywords changed in Photos: the new list replaces the old one.
        try await store.save([entry("a", "a.jpg")], keywords: ["a": ["Summer"]])
        #expect(try await store.keywords(of: "a") == ["Summer"])
        #expect(try await store.keywords(of: "b") == ["Winter"])

        try await store.save([entry("a", "a.jpg")])
        #expect(try await store.keywords(of: "a").isEmpty)

        try await store.delete(ids: ["b"])
        #expect(try await store.keywords(of: "b").isEmpty)
        #expect(try await store.search("winter") == [])
    }

    @Test func searchesNamesByAnyPartWhateverTheCase() async throws {
        let store = try makeStore()
        try await store.save([entry("fuji", "DSCF1234.RAF"), entry("canon", "IMG_0204.CR2"), entry("phone", "IMG_1234.HEIC"), entry("nameless", nil)])

        #expect(try await Set(store.search("1234") ?? []) == ["fuji", "phone"])
        #expect(try await store.search("dscf12") == ["fuji"])
        #expect(try await store.search(".cr2") == ["canon"])
        #expect(try await Set(store.search("IMG") ?? []) == ["canon", "phone"])
        #expect(try await store.search("nothing") == [])
    }

    @Test func searchesKeywordsWithoutAccents() async throws {
        let store = try makeStore()
        try await store.save([entry("a", "a.jpg"), entry("b", "b.jpg"), entry("c", "Été 2024.jpg")],
                             keywords: ["a": ["Été", "Écosse"], "b": ["Hiver"]])

        #expect(try await Set(store.search("ete") ?? []) == ["a", "c"])
        #expect(try await Set(store.search("ÉTÉ") ?? []) == ["a", "c"])
        #expect(try await store.search("ecos") == ["a"])
        #expect(try await store.search("hiver") == ["b"])
    }

    @Test func everyWordMustMatchANameOrAKeyword() async throws {
        let store = try makeStore()
        try await store.save([entry("a", "DSCF1234.RAF"), entry("b", "DSCF1299.RAF"), entry("c", "IMG_1234.JPG")],
                             keywords: ["a": ["Lapland"], "b": ["Lapland", "Aurora"], "c": ["Lapland"]])

        #expect(try await Set(store.search("lapland") ?? []) == ["a", "b", "c"])
        #expect(try await Set(store.search("lapland dscf") ?? []) == ["a", "b"])
        #expect(try await store.search("  aurora   12 ") == ["b"])
        #expect(try await store.search("lapland 1234 raf") == ["a"])
    }

    @Test func searchTakesWildcardCharactersLiterally() async throws {
        let store = try makeStore()
        try await store.save([entry("underscore", "IMG_0204.JPG"), entry("plain", "IMGX0204.JPG"), entry("percent", "100% crop.jpg")])

        #expect(try await store.search("img_") == ["underscore"])
        #expect(try await store.search("0%") == ["percent"])
    }

    @Test func searchWithoutAWordIsNoSearch() async throws {
        let store = try makeStore()
        try await store.save([entry("a", "a.jpg")])
        #expect(try await store.search("") == nil)
        #expect(try await store.search("   ") == nil)
    }

    @Test func listsOnlyTheAssetsWithAPosition() async throws {
        let store = try makeStore()
        let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522), sydney = GeoCoordinate(latitude: -33.8688, longitude: 151.2093)
        try await store.save([
            PhotosAssetEntry(id: "a", fileName: "a.jpg", captureDate: Date(timeIntervalSince1970: 100), isRAW: false, location: paris),
            PhotosAssetEntry(id: "b", fileName: "b.jpg", captureDate: nil, isRAW: false, location: sydney),
            entry("c", "c.jpg"),
        ])

        let located = try await store.locatedAssets().sorted { $0.id < $1.id }
        #expect(located == [
            LocatedAsset(id: "a", coordinate: paris, captureDate: Date(timeIntervalSince1970: 100)),
            LocatedAsset(id: "b", coordinate: sydney, captureDate: nil),
        ])
    }

    @Test func keepsTheChangeTokenUntilReset() async throws {
        let store = try makeStore()
        #expect(try await store.changeToken() == nil)

        try await store.setChangeToken(Data([1]))
        try await store.setChangeToken(Data([2]))
        #expect(try await store.changeToken() == Data([2]))

        try await store.save([entry("a", "a.jpg")])
        try await store.reset()
        #expect(try await store.changeToken() == nil)
        #expect(try await store.count() == 0)
    }
}
