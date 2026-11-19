import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

@MainActor
struct LibraryFilterSettingsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)

    @Test func nothingIsAskedUntilABoxIsChecked() {
        var settings = LibraryFilterSettings(now: day(2026, 11, 19, hour: 15), calendar: calendar)
        #expect(!settings.hasChoices && settings.filters(calendar: calendar).isEmpty)
        #expect(settings.firstDay == day(2025, 11, 19, hour: 15), "the dates start as the last year")

        // Values chosen while a box is unchecked wait for it.
        settings.rating = RatingFilter(.exactly, 5)
        settings.place = paris
        #expect(settings.filters(calendar: calendar).isEmpty)
        settings.filtersRating = true
        settings.filtersPlace = true
        settings.favoritesOnly = true
        let filters = settings.filters(calendar: calendar)
        #expect(filters.rating == RatingFilter(.exactly, 5) && filters.favoritesOnly && filters.place == PlaceFilter(center: paris, radius: 25000))
        #expect(settings.hasChoices)
    }

    @Test func theSwitchKeepsTheChoicesButAsksNothing() {
        var settings = LibraryFilterSettings(now: day(2026, 11, 19), calendar: calendar)
        settings.filtersFlag = true
        settings.rawOnly = true
        settings.isEnabled = false
        #expect(settings.filters(calendar: calendar).isEmpty && settings.hasChoices)
        settings.isEnabled = true
        #expect(settings.filters(calendar: calendar).flag == .picked && settings.filters(calendar: calendar).rawOnly)
    }

    @Test func datesAreWholeDaysOfTheCalendar() {
        var settings = LibraryFilterSettings(now: day(2026, 11, 19), calendar: calendar)
        settings.filtersDates = true
        settings.firstDay = day(2026, 3, 28, hour: 17)
        settings.lastDay = day(2026, 3, 29, hour: 9)
        // March 29, 2026 is 23 hours long in Paris: the day after starts where the calendar says.
        #expect(settings.filters(calendar: calendar).captureDates == day(2026, 3, 28) ..< day(2026, 3, 30))

        // Entered the wrong way round, the same days.
        settings.firstDay = day(2026, 3, 29, hour: 9)
        settings.lastDay = day(2026, 3, 28, hour: 17)
        #expect(settings.filters(calendar: calendar).captureDates == day(2026, 3, 28) ..< day(2026, 3, 30))
    }

    @Test func aPlaceNeedsACenterAndARadiusWithinReason() {
        var settings = LibraryFilterSettings(now: day(2026, 11, 19), calendar: calendar)
        settings.filtersPlace = true
        #expect(settings.filters(calendar: calendar).isEmpty, "no place picked yet")
        settings.place = paris
        settings.radius = 5
        #expect(settings.filters(calendar: calendar).place?.radius == 50)
    }

    @Test func settingsReadFromFiltersAskForTheSame() {
        var filters = LibraryFilters()
        filters.rating = RatingFilter(.atMost, 2)
        filters.flag = .notRejected
        filters.edits = .notEdited
        filters.captureDates = day(2026, 1, 1) ..< day(2026, 2, 1)
        filters.place = PlaceFilter(center: paris, radius: 80000)
        let settings = LibraryFilterSettings(showing: filters, now: day(2026, 11, 19), calendar: calendar)
        #expect(settings.filters(calendar: calendar) == filters)
        #expect(calendar.component(.day, from: settings.lastDay) == 31, "the last day listed, not the day after")
    }

    @Test func aLibrarysPanelComesBackAsItWasLeft() {
        let panels = LibraryFilterPanels(calendar: calendar)
        let source = SampleLibrarySource(count: 6)
        let other = SampleLibrarySource(count: 2, idPrefix: "other")
        #expect(!panels.settings(for: source).hasChoices)

        var settings = panels.settings(for: source)
        settings.filtersRating = true
        settings.rating = RatingFilter(.atLeast, 4)
        settings.placeName = "Paris"
        panels.set(settings, for: source)
        #expect(source.query.filters.rating == RatingFilter(.atLeast, 4))
        #expect(other.query.filters.isEmpty && !panels.settings(for: other).hasChoices, "each library has its own")

        // Switched off, the panel still shows what was chosen.
        settings.isEnabled = false
        panels.set(settings, for: source)
        #expect(source.query.isUnfiltered)
        #expect(panels.settings(for: source) == settings)
    }

    @Test func filtersSetByOtherMeansShowInThePanel() {
        let panels = LibraryFilterPanels(calendar: calendar)
        let source = SampleLibrarySource(count: 6)
        var settings = panels.settings(for: source)
        settings.favoritesOnly = true
        panels.set(settings, for: source)

        source.query = source.query.clearingFilters
        #expect(!panels.settings(for: source).hasChoices)
        source.query.filters.rawOnly = true
        #expect(panels.settings(for: source).rawOnly && !panels.settings(for: source).favoritesOnly)
    }

    @Test func aSpanOfTimeEndsTodayAndStartsThatLongAgo() {
        let now = day(2026, 11, 19, hour: 15)
        #expect(RelativeDateSpan(7, .days).dates(endingOn: now, calendar: calendar) == day(2026, 11, 12) ..< day(2026, 11, 20))
        #expect(RelativeDateSpan(2, .weeks).dates(endingOn: now, calendar: calendar) == day(2026, 11, 5) ..< day(2026, 11, 20))
        #expect(RelativeDateSpan(1, .years).dates(endingOn: now, calendar: calendar) == day(2025, 11, 19) ..< day(2026, 11, 20))
        // A month back from the 31st is the last day of a shorter month.
        #expect(RelativeDateSpan(1, .months).dates(endingOn: day(2026, 3, 31), calendar: calendar) == day(2026, 2, 28) ..< day(2026, 4, 1))
        #expect(RelativeDateSpan(0, .days).dates(endingOn: now, calendar: calendar) == day(2026, 11, 18) ..< day(2026, 11, 20), "at least one")
    }

    @Test func datesThatFollowTheDaysAreAskedFromToday() {
        var settings = LibraryFilterSettings(now: day(2026, 11, 19), calendar: calendar)
        settings.filtersDates = true
        settings.relativeDates = RelativeDateSpan(30, .days)
        #expect(settings.filters(now: day(2026, 11, 19, hour: 9), calendar: calendar).captureDates == day(2026, 10, 20) ..< day(2026, 11, 20))
        #expect(settings.filters(now: day(2026, 11, 20, hour: 9), calendar: calendar).captureDates == day(2026, 10, 21) ..< day(2026, 11, 21))

        // The same dates today, entered as two days, aren't the same thing asked: they stay put.
        var fixed = settings
        fixed.relativeDates = nil
        fixed.firstDay = day(2026, 10, 20)
        fixed.lastDay = day(2026, 11, 19)
        let now = day(2026, 11, 19, hour: 9)
        #expect(fixed.filters(now: now, calendar: calendar) == settings.filters(now: now, calendar: calendar))
        #expect(!fixed.asksTheSame(as: settings, now: now, calendar: calendar))

        // What waits behind an unchecked box doesn't count.
        var other = settings
        other.rating = RatingFilter(.exactly, 1)
        other.placeName = "Paris"
        #expect(other.asksTheSame(as: settings, now: now, calendar: calendar))
        other.filtersRating = true
        #expect(!other.asksTheSame(as: settings, now: now, calendar: calendar))
    }

    @Test func settingsSavedBeforeSpansOfTimeStillRead() throws {
        var settings = LibraryFilterSettings(now: day(2026, 11, 19), calendar: calendar)
        settings.filtersDates = true
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(json["relativeDates"] == nil)
        json["relativeDates"] = nil
        #expect(try JSONDecoder().decode(LibraryFilterSettings.self, from: JSONSerialization.data(withJSONObject: json)) == settings)

        settings.relativeDates = RelativeDateSpan(3, .months)
        #expect(try JSONDecoder().decode(LibraryFilterSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func theLastDaysMoveOnWhenTheDayChanges() {
        final class Clock {
            var now: Date
            init(_ now: Date) {
                self.now = now
            }
        }
        let clock = Clock(day(2026, 11, 19, hour: 23))
        let panels = LibraryFilterPanels(calendar: calendar) { clock.now }
        let moving = SampleLibrarySource(count: 3)
        let fixed = SampleLibrarySource(count: 3, idPrefix: "fixed")
        let elsewhere = SampleLibrarySource(count: 3, idPrefix: "elsewhere")
        var settings = LibraryFilterSettings(now: clock.now, calendar: calendar)
        settings.filtersDates = true
        panels.set(settings, for: fixed)
        settings.relativeDates = RelativeDateSpan(7, .days)
        panels.set(settings, for: moving)
        panels.set(settings, for: elsewhere)
        elsewhere.query.filters.favoritesOnly = true
        let fixedDates = fixed.query.filters.captureDates
        #expect(moving.query.filters.captureDates == day(2026, 11, 12) ..< day(2026, 11, 20))

        clock.now = day(2026, 11, 20, hour: 0)
        #expect(panels.settings(for: moving).relativeDates == RelativeDateSpan(7, .days), "still the last 7 days, not two days of yesterday's")
        panels.dayChanged()
        #expect(moving.query.filters.captureDates == day(2026, 11, 13) ..< day(2026, 11, 21))
        #expect(panels.settings(for: moving) == settings)
        #expect(fixed.query.filters.captureDates == fixedDates, "two days entered stay put")
        #expect(elsewhere.query.filters.captureDates == day(2026, 11, 12) ..< day(2026, 11, 20), "filtered by other means since: left alone")
    }

    @Test func theEditsBoxListsTheEditedPhotosUnlessToldOtherwise() {
        var settings = LibraryFilterSettings(now: day(2026, 11, 19), calendar: calendar)
        settings.edits = .notEdited
        #expect(settings.filters(calendar: calendar).edits == nil, "unchecked")
        settings.editedOnly = true
        #expect(settings.filters(calendar: calendar).edits == .notEdited)
        // As presets saved before the choice existed read.
        settings.edits = nil
        #expect(settings.filters(calendar: calendar).edits == .edited)
    }
}
