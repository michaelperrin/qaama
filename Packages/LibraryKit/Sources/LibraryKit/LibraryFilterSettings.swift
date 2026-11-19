import Foundation
import ImageIOKit
import Observation

/// What the Filter panel of a library shows: a checkbox per filter, the value each one keeps while
/// unchecked, and the panel's switch. `filters(now:calendar:)` is what the library is then asked.
///
/// Apart from `LibraryFilters`, which only says what applies: a filter switched off for a moment
/// keeps its stars, its dates and its place here. Codable to be saved as a preset (`FilterPreset`).
public nonisolated struct LibraryFilterSettings: Hashable, Codable, Sendable {
    /// The radii the panel offers, in meters: from a building and its street to a country. Not
    /// less: a phone places a photo to some ten meters at best.
    public static let radiusRange: ClosedRange<Double> = 50 ... 1_000_000

    /// The panel's switch: off, the choices below are kept but none applies.
    public var isEnabled = true
    public var favoritesOnly = false
    /// The Edits box. Named as when it only listed edited photos, so presets saved then still read.
    public var editedOnly = false
    /// Which photos the Edits box lists; nil, as in presets saved before the choice, is the edited ones.
    public var edits: EditsFilter?
    public var rawOnly = false
    public var filtersRating = false
    public var rating = RatingFilter(.atLeast, 3)
    public var filtersFlag = false
    public var flag = FlagFilter.picked
    public var filtersDates = false
    /// The first and last days listed: any moment of each, in the user's calendar.
    public var firstDay: Date
    public var lastDay: Date
    /// The dates as a span of time ending today, which moves on with the days; nil for the two
    /// days above. Optional, so presets saved before it existed still read.
    public var relativeDates: RelativeDateSpan?
    public var filtersPlace = false
    /// The center of the place; nil until one is picked, and the filter then asks nothing.
    public var place: GeoCoordinate?
    /// What the place was found under, to show in the panel; empty for a point picked on the map.
    public var placeName = ""
    /// In meters.
    public var radius = 25000.0

    /// Nothing checked; the dates start as the year ending at `now`.
    public init(now: Date = .now, calendar: Calendar = .current) {
        lastDay = now
        firstDay = calendar.date(byAdding: .year, value: -1, to: now) ?? now
    }

    /// The settings that show these filters, as a panel opened on a library filtered elsewhere.
    public init(showing filters: LibraryFilters, now: Date = .now, calendar: Calendar = .current) {
        self.init(now: now, calendar: calendar)
        favoritesOnly = filters.favoritesOnly
        editedOnly = filters.edits != nil
        edits = filters.edits
        rawOnly = filters.rawOnly
        if let rating = filters.rating {
            filtersRating = true
            self.rating = rating
        }
        if let flag = filters.flag {
            filtersFlag = true
            self.flag = flag
        }
        if let dates = filters.captureDates {
            filtersDates = true
            firstDay = dates.lowerBound
            // The upper bound is the start of the day after the last one.
            lastDay = max(dates.lowerBound, dates.upperBound.addingTimeInterval(-1))
        }
        if let place = filters.place {
            filtersPlace = true
            self.place = place.center
            radius = place.radius
        }
    }

    /// True when a box is checked: there is something to reset.
    public var hasChoices: Bool {
        favoritesOnly || editedOnly || rawOnly || filtersRating || filtersFlag || filtersDates || filtersPlace
    }

    /// True when both ask a library the same thing, today and tomorrow: the same filters, and dates
    /// that move on with the days in both or in neither. Values waiting behind an unchecked box
    /// don't count.
    public func asksTheSame(as other: LibraryFilterSettings, now: Date = .now, calendar: Calendar = .current) -> Bool {
        filters(now: now, calendar: calendar) == other.filters(now: now, calendar: calendar) && movingDates == other.movingDates
    }

    /// The span the dates asked follow, when they do.
    private var movingDates: RelativeDateSpan? {
        isEnabled && filtersDates ? relativeDates : nil
    }

    /// What the library is asked: the checked filters while the panel's switch is on. Days are the
    /// calendar's, the last one included whole; dates entered the wrong way round are swapped. A
    /// span of time ends with the day of `now`.
    public func filters(now: Date = .now, calendar: Calendar = .current) -> LibraryFilters {
        var filters = LibraryFilters()
        guard isEnabled else { return filters }
        filters.favoritesOnly = favoritesOnly
        if editedOnly {
            filters.edits = edits ?? .edited
        }
        filters.rawOnly = rawOnly
        if filtersRating {
            filters.rating = rating
        }
        if filtersFlag {
            filters.flag = flag
        }
        if filtersDates, let relativeDates {
            filters.captureDates = relativeDates.dates(endingOn: now, calendar: calendar)
        } else if filtersDates {
            let start = calendar.startOfDay(for: min(firstDay, lastDay))
            let lastStart = calendar.startOfDay(for: max(firstDay, lastDay))
            let end = calendar.date(byAdding: .day, value: 1, to: lastStart) ?? lastStart.addingTimeInterval(86400)
            filters.captureDates = start ..< end
        }
        if filtersPlace, let place {
            let radius = min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
            filters.place = PlaceFilter(center: place, radius: radius)
        }
        return filters
    }
}

/// A length of time counted back from today: "the last 30 days", "the last 2 years".
public nonisolated struct RelativeDateSpan: Hashable, Codable, Sendable {
    public enum Unit: String, CaseIterable, Codable, Sendable {
        case days
        case weeks
        case months
        case years
    }

    /// The amounts the panel offers.
    public static let amountRange = 1 ... 999

    public var amount: Int
    public var unit: Unit

    public init(_ amount: Int, _ unit: Unit) {
        self.amount = amount
        self.unit = unit
    }

    /// The dates the span covers on the day of `now`: from the same day that long ago (January 19
    /// for a month back from February 19) to the end of today, whole days of the calendar.
    public func dates(endingOn now: Date, calendar: Calendar = .current) -> Range<Date> {
        let amount = min(max(amount, Self.amountRange.lowerBound), Self.amountRange.upperBound)
        let component: Calendar.Component = switch unit {
        case .days: .day
        case .weeks: .weekOfYear
        case .months: .month
        case .years: .year
        }
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: component, value: -amount, to: today).map(calendar.startOfDay) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        return start ..< end
    }
}

/// The Filter panels' settings, one per library, for as long as the library lives: the panel of a
/// library comes back as it was left, unchecked values and switch included, in every window.
///
/// The library's query stays the truth of what applies: settings that no longer say what was asked
/// of it (filters set by other means) give way to settings read from it. Dates that follow the
/// days ("the last 30 days") are asked again when the day changes.
@Observable
public final class LibraryFilterPanels {
    private struct Entry {
        weak var source: (any LibrarySource)?
        var settings: LibraryFilterSettings
        /// What the settings asked of the library when they were set.
        var asked: LibraryFilters
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var dayChanges: Task<Void, Never>?

    /// `now` tells the time, for tests to move it.
    public init(calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        self.calendar = calendar
        self.now = now
        // The system says when the day changes, at midnight or on waking from sleep after it.
        let changes = NotificationCenter.default.notifications(named: .NSCalendarDayChanged).map { _ in () }
        dayChanges = Task { [weak self] in
            for await _ in changes {
                self?.dayChanged()
            }
        }
    }

    isolated deinit {
        dayChanges?.cancel()
    }

    public func settings(for source: any LibrarySource) -> LibraryFilterSettings {
        // The identifier of a library that is gone may be given to another one.
        if let entry = entries[ObjectIdentifier(source)], entry.source === source, entry.asked == source.query.filters {
            return entry.settings
        }
        return LibraryFilterSettings(showing: source.query.filters, now: now(), calendar: calendar)
    }

    /// Keeps the settings and asks the library for what they say, when that changed.
    public func set(_ settings: LibraryFilterSettings, for source: any LibrarySource) {
        entries = entries.filter { $0.value.source != nil }
        let filters = settings.filters(now: now(), calendar: calendar)
        entries[ObjectIdentifier(source)] = Entry(source: source, settings: settings, asked: filters)
        if source.query.filters != filters {
            source.query.filters = filters
        }
    }

    /// Asks again the libraries whose settings say something else today than when they were set:
    /// those with dates that follow the days. Libraries filtered by other means since are left alone.
    func dayChanged() {
        for entry in entries.values {
            guard let source = entry.source, entry.asked == source.query.filters,
                  entry.settings.filters(now: now(), calendar: calendar) != entry.asked else { continue }
            set(entry.settings, for: source)
        }
    }
}
