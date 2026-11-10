import Foundation
import LibraryKit
import Testing

struct DateTimelineTests {
    /// A fixed calendar, so the tests don't depend on where they run.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func timeline(_ dates: [Date?]) -> DateTimeline {
        DateTimeline(dates: dates, calendar: Self.calendar)
    }

    @Test func groupsANewestFirstListingByMonth() {
        let timeline = timeline([
            Self.date(2017, 6, 3), Self.date(2017, 6, 1),
            Self.date(2017, 5, 28), Self.date(2017, 5, 12), Self.date(2017, 5, 2),
            Self.date(2016, 12, 25),
        ])
        #expect(timeline.sections.map(\.month) == [YearMonth(year: 2017, month: 6), YearMonth(year: 2017, month: 5), YearMonth(year: 2016, month: 12)])
        #expect(timeline.sections.map(\.range) == [0 ..< 2, 2 ..< 5, 5 ..< 6])
        #expect(timeline.count == 6)
        #expect(timeline.years == [2017, 2016])
        #expect(timeline.counts[YearMonth(year: 2017, month: 5)] == 3)
    }

    @Test func groupsAnOldestFirstListingToo() {
        let timeline = timeline([Self.date(2016, 12, 25), Self.date(2017, 5, 2), Self.date(2017, 5, 12)])
        #expect(timeline.sections.map(\.range) == [0 ..< 1, 1 ..< 3])
        #expect(timeline.years == [2016, 2017])
    }

    @Test func monthsBreakAtMidnightOfTheCalendar() throws {
        // 23:30 on May 31 and 00:30 on June 1, Paris time: an hour apart, two months.
        let last = try #require(Self.calendar.date(from: DateComponents(year: 2017, month: 5, day: 31, hour: 23, minute: 30)))
        let first = try #require(Self.calendar.date(from: DateComponents(year: 2017, month: 6, day: 1, hour: 0, minute: 30)))
        let timeline = timeline([first, last])
        #expect(timeline.sections.map(\.month?.month) == [6, 5])
        // The first instant of a month belongs to it, not to the month before.
        let midnight = Self.date(2017, 6, 1, hour: 0)
        #expect(self.timeline([last, midnight]).sections.map(\.month?.month) == [5, 6])
    }

    @Test func photosWithoutADateFormTheirOwnSection() {
        let timeline = timeline([Self.date(2017, 5, 2), Self.date(2017, 5, 1), nil, nil])
        #expect(timeline.sections.count == 2)
        #expect(timeline.sections[1].month == nil)
        #expect(timeline.sections[1].range == 2 ..< 4)
        #expect(timeline.counts.count == 1)
        #expect(timeline.years == [2017])
    }

    @Test func findsTheSectionOfARowAndOfAMonth() {
        let timeline = timeline([Self.date(2017, 6, 3), Self.date(2017, 5, 28), Self.date(2017, 5, 12), Self.date(2016, 12, 25)])
        #expect(timeline.section(containing: 0)?.month == YearMonth(year: 2017, month: 6))
        #expect(timeline.section(containing: 2)?.month == YearMonth(year: 2017, month: 5))
        #expect(timeline.section(containing: 3)?.month == YearMonth(year: 2016, month: 12))
        #expect(timeline.section(containing: 4) == nil)
        #expect(timeline.section(containing: -1) == nil)
        #expect(timeline.section(for: YearMonth(year: 2017, month: 5))?.range == 1 ..< 3)
        #expect(timeline.section(for: YearMonth(year: 2017, month: 4)) == nil)
    }

    @Test func aMonthTheListingComesBackToGetsADistinctIdentifier() {
        // Not sorted: May, June, May again. Sections stay consecutive rows and their identifiers unique.
        let timeline = timeline([Self.date(2017, 5, 2), Self.date(2017, 6, 2), Self.date(2017, 5, 3)])
        #expect(timeline.sections.map(\.range) == [0 ..< 1, 1 ..< 2, 2 ..< 3])
        #expect(Set(timeline.sections.map(\.id)).count == 3)
        #expect(timeline.counts[YearMonth(year: 2017, month: 5)] == 2)
        #expect(timeline.section(for: YearMonth(year: 2017, month: 5))?.range == 0 ..< 1)
    }

    @Test func sectionIdentifiersSurviveAPhotoAddedElsewhere() {
        let before = timeline([Self.date(2017, 6, 3), Self.date(2017, 5, 28)])
        let after = timeline([Self.date(2017, 7, 1), Self.date(2017, 6, 3), Self.date(2017, 5, 28)])
        #expect(before.sections.map(\.id) == Array(after.sections.map(\.id).dropFirst()))
    }

    @Test func fitsAListingThatGrewOrShrank() {
        let timeline = timeline([Self.date(2017, 6, 3), Self.date(2017, 5, 28), Self.date(2017, 5, 12), Self.date(2016, 12, 25)])
        #expect(timeline.fitted(to: 4) == timeline)
        // Shorter: sections past the end go, the one across it is cut.
        #expect(timeline.fitted(to: 2).sections.map(\.range) == [0 ..< 1, 1 ..< 2])
        // Longer: the last section takes the rows nothing is known about yet.
        #expect(timeline.fitted(to: 6).sections.map(\.range) == [0 ..< 1, 1 ..< 3, 3 ..< 6])
        #expect(timeline.fitted(to: 0).sections.isEmpty)
        #expect(self.timeline([]).fitted(to: 3).sections.map(\.range) == [0 ..< 3])
    }

    @Test func theRowsNotReadYetAreOnePendingSection() {
        var builder = DateTimeline.Builder(calendar: Self.calendar)
        [Self.date(2017, 6, 3), Self.date(2017, 5, 28)].forEach { builder.append($0) }
        let partial = builder.timeline(pendingUpTo: 10)
        #expect(!partial.isComplete)
        #expect(partial.count == 10)
        #expect(partial.sections.map(\.range) == [0 ..< 1, 1 ..< 2, 2 ..< 10])
        #expect(partial.sections.last?.isPending == true)
        #expect(partial.counts.count == 2)
        // The months read first keep their identifiers once the rest is read, and the pending
        // section isn't mistaken for the photos without a date.
        [nil, Self.date(2016, 1, 1)].forEach { builder.append($0) }
        let complete = builder.timeline(pendingUpTo: 4)
        #expect(complete.isComplete)
        #expect(Array(complete.sections.map(\.id).prefix(2)) == Array(partial.sections.map(\.id).prefix(2)))
        #expect(complete.sections[2].id != partial.sections[2].id)
    }

    @Test func anEmptyListingHasNoSection() {
        let timeline = timeline([])
        #expect(timeline.sections.isEmpty)
        #expect(timeline.count == 0)
        #expect(DateTimeline.undated(count: 0).sections.isEmpty)
        #expect(DateTimeline.undated(count: 5).sections.map(\.range) == [0 ..< 5])
    }

    @Test func buildsALargeListingFast() {
        // 74,000 photos over twelve years, newest first: the size of the maintainer's library.
        let newest = Self.date(2026, 11, 1)
        let step = 12 * 365.25 * 86400 / 74000
        let dates: [Date?] = (0 ..< 74000).map { newest.addingTimeInterval(-Double($0) * step) }
        let clock = ContinuousClock()
        var timeline = DateTimeline(dates: [])
        let duration = clock.measure { timeline = self.timeline(dates) }
        #expect(timeline.count == 74000)
        #expect(timeline.sections.count == 145)
        // A few milliseconds in a Debug build; the bound only catches a return to one calendar call per photo.
        #expect(duration < .milliseconds(250))
    }

    @Test func yearMonthsOrderAndGiveTheirFirstInstant() {
        #expect(YearMonth(year: 2016, month: 12) < YearMonth(year: 2017, month: 1))
        #expect(YearMonth(year: 2017, month: 5) < YearMonth(year: 2017, month: 6))
        #expect(YearMonth(year: 2017, month: 5).start(in: Self.calendar) == Self.date(2017, 5, 1, hour: 0))
        #expect(YearMonth(Self.date(2017, 5, 31), calendar: Self.calendar) == YearMonth(year: 2017, month: 5))
    }
}
