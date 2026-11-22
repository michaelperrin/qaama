import Foundation
@testable import LibraryKit
import Testing

struct PhotosFetchPredicateTests {
    /// An asset as the predicate sees it: the keys PhotoKit evaluates.
    private func asset(_ id: String, favorite: Bool = false, rating: Int = 0, mediaType: Int = 1, date: TimeInterval = 0) -> NSDictionary {
        ["localIdentifier": id, "isFavorite": favorite, "rating": rating, "mediaType": mediaType, "creationDate": Date(timeIntervalSince1970: date)]
    }

    private var index: PhotosIndexSnapshot {
        PhotosIndexSnapshot(rawIDs: ["raw", "pair-raw"], pairs: [PhotosAssetPair(rawID: "pair-raw", twinID: "pair-jpeg")])
    }

    private func matches(_ query: LibraryQuery, index: PhotosIndexSnapshot?, native: Set<QueryCapability> = [.favorite, .rating],
                         search: [String]? = nil, trash: Set<String> = [], listsTrash: Bool = false) -> [String]
    {
        // No predicate: nothing can match, the source lists nothing.
        guard let predicate = PhotosFetchPredicate.make(query: query, native: native, index: index, indexMatches: search,
                                                        trash: trash, listsTrash: listsTrash) else { return [] }
        let library = [asset("raw", favorite: true, rating: 4, date: 100), asset("pair-raw", date: 200), asset("pair-jpeg", rating: 5, date: 200),
                       asset("jpeg", favorite: true, date: 300), asset("video", mediaType: 2)]
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
        query.filters.rawOnly = true
        #expect(matches(query, index: index) == ["raw", "pair-raw"])

        // The twins aren't RAW, shown or not.
        query.includesPairedJPEGs = true
        #expect(matches(query, index: index) == ["raw", "pair-raw"])
    }

    @Test func combinesWithTheNativeFilters() {
        var query = LibraryQuery()
        query.filters.rawOnly = true
        query.filters.favoritesOnly = true
        query.filters.rating = .atLeast(3)
        #expect(matches(query, index: index) == ["raw"])

        // A system whose PhotoKit doesn't filter on ratings ignores that part.
        #expect(matches(query, index: index, native: [.favorite]) == ["raw"])
        query.filters.favoritesOnly = false
        #expect(matches(query, index: index, native: [.favorite]) == ["raw", "pair-raw"])
    }

    @Test func comparesRatingsEitherWay() {
        var query = LibraryQuery()
        query.includesPairedJPEGs = true
        query.filters.rating = RatingFilter(.atLeast, 4)
        #expect(matches(query, index: index) == ["raw", "pair-jpeg"])
        query.filters.rating = RatingFilter(.atMost, 4)
        #expect(matches(query, index: index) == ["raw", "pair-raw", "jpeg"])
        query.filters.rating = RatingFilter(.exactly, 0)
        #expect(matches(query, index: index) == ["pair-raw", "jpeg"])
    }

    @Test func keepsThePhotosTakenWithinTheDates() {
        var query = LibraryQuery()
        query.filters.captureDates = Date(timeIntervalSince1970: 100) ..< Date(timeIntervalSince1970: 300)
        #expect(matches(query, index: index) == ["raw", "pair-raw"])
        // Native, so without an index too.
        #expect(matches(query, index: nil) == ["raw", "pair-raw", "pair-jpeg"])
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
        query.filters.rawOnly = true
        #expect(matches(query, index: index, search: ["raw", "jpeg", "pair-jpeg"]) == ["raw"])

        query.filters.rawOnly = false
        query.filters.favoritesOnly = true
        #expect(matches(query, index: index, search: ["raw", "pair-raw"]) == ["raw"])
    }

    @Test func nothingToListWhenTheListsAreEmpty() {
        var query = LibraryQuery()
        query.searchText = "anything"
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, indexMatches: []) == nil)
        // Found photos, none of them RAW.
        query.filters.rawOnly = true
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, indexMatches: ["jpeg"]) == nil)
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

        query.filters.rawOnly = true
        #expect(matches(query, index: index) == ["raw"])
        query.filters.rawOnly = false
        query.searchText = "anything"
        #expect(matches(query, index: index, search: ["jpeg", "pair-raw"]) == ["jpeg"])
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, indexMatches: ["pair-raw"]) == nil)
    }

    @Test func withoutAnIndexOnlyNativeFiltersApply() {
        var query = LibraryQuery()
        query.filters.rawOnly = true
        #expect(matches(query, index: nil) == ["raw", "pair-raw", "pair-jpeg", "jpeg"])
    }

    @Test func leavesOutThePhotosDeletedInQaama() {
        var query = LibraryQuery()
        #expect(matches(query, index: index, trash: ["raw", "pair-jpeg"]) == ["pair-raw", "jpeg"])
        // Without an index too: the trash doesn't come from it.
        #expect(matches(query, index: nil, trash: ["raw"]) == ["pair-raw", "pair-jpeg", "jpeg"])

        // Whatever else narrows the listing.
        query.filters.rawOnly = true
        #expect(matches(query, index: index, trash: ["raw"]) == ["pair-raw"])
        query.filters.rawOnly = false
        query.searchText = "anything"
        #expect(matches(query, index: index, search: ["raw", "jpeg"], trash: ["jpeg"]) == ["raw"])
        query.onlyAssetIDs = ["jpeg"]
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, indexMatches: ["raw", "jpeg"], trash: ["jpeg"]) == nil)
    }

    @Test func recentlyDeletedListsOnlyTheDeletedPhotos() {
        var query = LibraryQuery()
        #expect(matches(query, index: index, trash: ["raw", "jpeg"], listsTrash: true) == ["raw", "jpeg"])
        #expect(PhotosFetchPredicate.make(query: query, native: [], index: index, trash: [], listsTrash: true) == nil, "an empty trash lists nothing")

        // A pair deleted as one photo shows as one; a twin deleted alone is a photo of its own.
        #expect(matches(query, index: index, trash: ["pair-raw", "pair-jpeg"], listsTrash: true) == ["pair-raw"])
        #expect(matches(query, index: index, trash: ["pair-jpeg", "jpeg"], listsTrash: true) == ["pair-jpeg", "jpeg"])
        query.includesPairedJPEGs = true
        #expect(matches(query, index: index, trash: ["pair-raw", "pair-jpeg"], listsTrash: true) == ["pair-raw", "pair-jpeg"])

        // The filters apply there as anywhere.
        query.filters.favoritesOnly = true
        #expect(matches(query, index: index, trash: ["raw", "pair-raw"], listsTrash: true) == ["raw"])
    }
}
