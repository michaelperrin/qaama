import Foundation
import LibraryKit
import Testing

struct GridMoveTests {
    /// Two months: 10 photos (rows of 4: 0-3, 4-7, 8-9), then 3 photos (10-12).
    private let timeline: DateTimeline = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let june = calendar.date(from: DateComponents(year: 2017, month: 6, day: 10))!
        let may = calendar.date(from: DateComponents(year: 2017, month: 5, day: 10))!
        return DateTimeline(dates: Array(repeating: june, count: 10) + Array(repeating: may, count: 3), calendar: calendar)
    }()

    @Test func leftAndRightStepThroughTheListingAcrossSections() {
        #expect(timeline.row(from: 9, moving: .right, columns: 4) == 10)
        #expect(timeline.row(from: 10, moving: .left, columns: 4) == 9)
        #expect(timeline.row(from: 0, moving: .left, columns: 4) == nil)
        #expect(timeline.row(from: 12, moving: .right, columns: 4) == nil)
    }

    @Test func upAndDownKeepTheColumnInsideASection() {
        #expect(timeline.row(from: 1, moving: .down, columns: 4) == 5)
        #expect(timeline.row(from: 5, moving: .up, columns: 4) == 1)
        #expect(timeline.row(from: 0, moving: .up, columns: 4) == nil)
    }

    @Test func downIntoAShortLastRowLandsOnItsLastPhoto() {
        #expect(timeline.row(from: 7, moving: .down, columns: 4) == 9)
        #expect(timeline.row(from: 4, moving: .down, columns: 4) == 8)
    }

    @Test func downFromTheLastRowEntersTheNextSection() {
        #expect(timeline.row(from: 8, moving: .down, columns: 4) == 10)
        #expect(timeline.row(from: 9, moving: .down, columns: 4) == 11)
        // The next section's first row is shorter than the column.
        #expect(timeline.row(from: 7, moving: .down, columns: 2) == 9)
        #expect(timeline.row(from: 9, moving: .down, columns: 8) == 11)
        #expect(timeline.row(from: 11, moving: .down, columns: 4) == nil)
    }

    @Test func upFromTheFirstRowEntersThePreviousSectionsLastRow() {
        #expect(timeline.row(from: 10, moving: .up, columns: 4) == 8)
        #expect(timeline.row(from: 11, moving: .up, columns: 4) == 9)
        #expect(timeline.row(from: 12, moving: .up, columns: 4) == 9)
    }

    @Test func anUndatedListingIsOneSection() {
        let timeline = DateTimeline.undated(count: 7)
        #expect(timeline.row(from: 2, moving: .down, columns: 3) == 5)
        #expect(timeline.row(from: 5, moving: .down, columns: 3) == 6)
        #expect(timeline.row(from: 6, moving: .down, columns: 3) == nil)
        #expect(timeline.row(from: 4, moving: .down, columns: 3) == 6)
        #expect(timeline.row(from: 3, moving: .up, columns: 3) == 0)
    }
}
