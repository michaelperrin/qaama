import Foundation
@testable import LibraryKit
import Testing

struct PhotosFetchPredicateTests {
    /// An asset as the predicate sees it: the keys PhotoKit evaluates.
    private func asset(_ id: String, favorite: Bool = false, rating: Int = 0, mediaType: Int = 1) -> NSDictionary {
        ["localIdentifier": id, "isFavorite": favorite, "rating": rating, "mediaType": mediaType]
    }

    private var index: PhotosIndexSnapshot {
        PhotosIndexSnapshot(rawIDs: ["raw", "pair-raw"], pairs: [PhotosAssetPair(rawID: "pair-raw", twinID: "pair-jpeg")])
    }

    private func matches(_ query: LibraryQuery, index: PhotosIndexSnapshot?, native: Set<QueryCapability> = [.favorite, .rating],
                         search: [String]? = nil) -> [String]
    {
        // No predicate: nothing can match, the source lists nothing.
        guard let predicate = PhotosFetchPredicate.make(query: query, native: native, index: index, searchMatches: search) else { return [] }
        let library = [asset("raw", favorite: true, rating: 4), asset("pair-raw"), asset("pair-jpeg", rating: 5), asset("jpeg", favorite: true),
                       asset("video", mediaType: 2)]
        return library.filter { predicate.evaluate(with: $0) }.compactMap { $0["localIdentifier"] as? String }
    }

    @Test func hidesJPEGTwinsUnlessAskedFor() {
        var query = LibraryQuery()
        #expect(matches(query, index: index) == ["raw", "pair-raw", "jpeg"])

        query.includesPairedJPEGs = true
        #expect(matches(query, index: index) == ["raw", "pair-raw", "pair-jpeg", "jpeg"])
    }

    @Test func rawOnlyKeepsTheLibrarysRAWSet() {
        var query = LibraryQuery()
        query.rawOnly = true
        #expect(matches(query, index: index) == ["raw", "pair-raw"])

        // The twins aren't RAW, shown or not.
        query.includesPairedJPEGs = true
        #expect(matches(query, index: index) == ["raw", "pair-raw"])
    }

    @Test func combinesWithTheNativeFilters() {
        var query = LibraryQuery()
        query.rawOnly = true
        query.favoritesOnly = true
        query.minimumRating = 3
        #expect(matches(query, index: index) == ["raw"])

        // A system whose PhotoKit doesn't filter on ratings ignores that part.
        #expect(matches(query, index: index, native: [.favorite]) == ["raw"])
        query.favoritesOnly = false
        #expect(matches(query, index: index, native: [.favorite]) == ["raw", "pair-raw"])
    }

    @Test func searchKeepsTheAssetsTheIndexFound() {
        var query = LibraryQuery()
        query.searchText = "anything"
        #expect(matches(query, index: index, search: ["jpeg", "raw"]) == ["raw", "jpeg"])

        // A found JPEG twin stays hidden unless twins are shown.
        #expect(matches(query, index: index, search: ["pair-jpeg", "jpeg"]) == ["jpeg"])
        query.includesPairedJPEGs = true
        #expect(matches(query, index: index, search: ["pair-jpeg", "jpeg"]) == ["pair-jpeg", "jpeg"])
    }

    @Test func searchCombinesWithRAWOnlyAndNativeFilters() {
        var query = LibraryQuery()
        query.searchText = "anything"
        query.rawOnly = true
        #expect(matches(query, index: index, search: ["raw", "jpeg", "pair-jpeg"]) == ["raw"])

        query.rawOnly = false
        query.favoritesOnly = true
        #expect(matches(query, index: index, search: ["raw", "pair-raw"]) == ["raw"])
    }

    @Test func nothingToListWhenTheListsAreEmpty() {
        var query = LibraryQuery()
        query.searchText = "anything"
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, searchMatches: []) == nil)
        // Found photos, none of them RAW.
        query.rawOnly = true
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, searchMatches: ["jpeg"]) == nil)
        // No RAW in the library at all.
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: PhotosIndexSnapshot()) == nil)
    }

    @Test func aGroupPickedOnTheMapNarrowsEveryOtherList() {
        var query = LibraryQuery()
        query.onlyAssetIDs = ["raw", "jpeg", "pair-jpeg"]
        // The twin of the group stays hidden like any other.
        #expect(matches(query, index: index) == ["raw", "jpeg"])
        // Without an index too: the group doesn't come from it.
        #expect(matches(query, index: nil) == ["raw", "pair-jpeg", "jpeg"])

        query.rawOnly = true
        #expect(matches(query, index: index) == ["raw"])
        query.rawOnly = false
        query.searchText = "anything"
        #expect(matches(query, index: index, search: ["jpeg", "pair-raw"]) == ["jpeg"])
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, searchMatches: ["pair-raw"]) == nil)
    }

    @Test func withoutAnIndexOnlyNativeFiltersApply() {
        var query = LibraryQuery()
        query.rawOnly = true
        #expect(matches(query, index: nil) == ["raw", "pair-raw", "pair-jpeg", "jpeg"])
    }
}
