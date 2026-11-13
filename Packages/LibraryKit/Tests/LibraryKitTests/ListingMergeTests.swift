import Foundation
@testable import LibraryKit
import Testing

struct ListingMergeTests {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A day of January 2026, at noon.
    private func day(_ day: Int, month: Int = 1) -> Date? {
        Self.utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))
    }

    private func order(_ merge: ListingMerge) -> [String] {
        merge.entries.map { "\(["A", "B", "C"][Int($0.listing)])\($0.row)" }
    }

    @Test func weavesNewestFirstListingsByDate() {
        let merge = ListingMerge(dates: [[day(9), day(5), day(1)], [day(7), day(6), day(2)]], ascending: false, calendar: Self.utc)

        #expect(order(merge) == ["A0", "B0", "B1", "A1", "B2", "A2"])
        #expect(merge.position(listing: 1, row: 1) == 2)
        #expect(merge.position(listing: 0, row: 2) == 5)
        #expect(merge.position(listing: 0, row: 3) == nil && merge.position(listing: 2, row: 0) == nil)
    }

    @Test func weavesOldestFirstListingsToo() {
        let merge = ListingMerge(dates: [[day(1), day(5), day(9)], [day(2), day(6)]], ascending: true, calendar: Self.utc)

        #expect(order(merge) == ["A0", "B0", "A1", "B1", "A2"])
    }

    @Test func equalDatesKeepTheOrderOfTheListings() {
        let merge = ListingMerge(dates: [[day(3), day(3)], [day(3)], [day(3)]], ascending: false, calendar: Self.utc)

        #expect(order(merge) == ["A0", "A1", "B0", "C0"])
    }

    @Test func photosWithoutADateComeLastWhateverTheOrder() {
        let newestFirst = ListingMerge(dates: [[day(9), nil], [day(5), day(1), nil]], ascending: false, calendar: Self.utc)
        #expect(order(newestFirst) == ["A0", "B0", "B1", "A1", "B2"])

        let oldestFirst = ListingMerge(dates: [[day(9), nil], [day(1), day(5), nil]], ascending: true, calendar: Self.utc)
        #expect(order(oldestFirst) == ["B0", "B1", "A0", "A1", "B2"])
    }

    @Test func aRowOutOfOrderStaysWithItsNeighbors() {
        // The second listing ends with a photo listed by another date than the one it shows.
        let merge = ListingMerge(dates: [[day(8), day(4)], [day(6), day(2), day(9)]], ascending: false, calendar: Self.utc)

        #expect(order(merge) == ["A0", "B0", "A1", "B1", "B2"])
    }

    @Test func givesTheMonthsOfTheMergedListing() {
        let merge = ListingMerge(dates: [[day(9, month: 3), day(5, month: 1)], [day(7, month: 3), day(6, month: 2), nil]],
                                 ascending: false, calendar: Self.utc)

        #expect(merge.timeline.count == 5)
        #expect(merge.timeline.sections.map(\.month) == [YearMonth(year: 2026, month: 3), YearMonth(year: 2026, month: 2), YearMonth(year: 2026, month: 1), nil])
        #expect(merge.timeline.sections.map(\.range) == [0 ..< 2, 2 ..< 3, 3 ..< 4, 4 ..< 5])
    }

    @Test func nothingToMergeIsAnEmptyListing() {
        #expect(ListingMerge(dates: [], ascending: false).entries.isEmpty)
        #expect(ListingMerge(dates: [[], []], ascending: false).entries.isEmpty)
        #expect(ListingMerge().timeline.count == 0)
    }
}
