import Foundation

/// A relative change of date: so many years, months, days, hours and minutes later or earlier. What
/// a camera whose clock was wrong, reset to a default date or left on another time zone, needs on
/// every photo it took.
public nonisolated struct DateShift: Hashable, Sendable {
    public enum Direction: Hashable, Sendable, CaseIterable {
        case later, earlier
    }

    /// Amounts are never negative: `direction` says which way. Typed values are clamped.
    public var years: Int {
        didSet { years = max(years, 0) }
    }

    public var months: Int {
        didSet { months = max(months, 0) }
    }

    public var days: Int {
        didSet { days = max(days, 0) }
    }

    public var hours: Int {
        didSet { hours = max(hours, 0) }
    }

    public var minutes: Int {
        didSet { minutes = max(minutes, 0) }
    }

    public var direction: Direction

    public init(years: Int = 0, months: Int = 0, days: Int = 0, hours: Int = 0, minutes: Int = 0, direction: Direction = .later) {
        self.years = max(years, 0)
        self.months = max(months, 0)
        self.days = max(days, 0)
        self.hours = max(hours, 0)
        self.minutes = max(minutes, 0)
        self.direction = direction
    }

    /// The shift that takes one date to another, to the minute: what to apply to every photo once the
    /// real date of one of them is known. Spelled in years, months and days when applying those to
    /// `date` lands on `target`; the calendar isn't symmetric around month ends, so it falls back on
    /// days, then on elapsed hours and minutes, which always land.
    public init(from date: Date, to target: Date, calendar: Calendar = .current) {
        let later = target >= date
        let spellings: [Set<Calendar.Component>] = [[.year, .month, .day, .hour, .minute], [.day, .hour, .minute], [.hour, .minute]]
        var found = DateShift()
        for units in spellings {
            let parts = later ? calendar.dateComponents(units, from: date, to: target) : calendar.dateComponents(units, from: target, to: date)
            found = DateShift(years: parts.year ?? 0, months: parts.month ?? 0, days: parts.day ?? 0, hours: parts.hour ?? 0,
                              minutes: parts.minute ?? 0, direction: later ? .later : .earlier)
            if abs(found.applied(to: date, calendar: calendar).timeIntervalSince(target)) < 60 {
                break
            }
        }
        self = found
    }

    /// True when the shift moves nothing.
    public var isZero: Bool {
        years == 0 && months == 0 && days == 0 && hours == 0 && minutes == 0
    }

    /// Years, months and days go through the calendar: a day later is the same time on the next day
    /// even across a daylight saving change, and a month after 31 January is the last day of
    /// February. Hours and minutes are elapsed time.
    public func applied(to date: Date, calendar: Calendar = .current) -> Date {
        let sign = direction == .later ? 1 : -1
        let components = DateComponents(year: sign * years, month: sign * months, day: sign * days, hour: sign * hours, minute: sign * minutes)
        return calendar.date(byAdding: components, to: date) ?? date
    }
}

/// How the capture date of a photo is corrected: replaced by a date, or moved by a shift.
public nonisolated enum DateAdjustment: Hashable, Sendable {
    case set(Date)
    case shift(DateShift)

    /// The corrected date, to the second. A photo without a date can be given one but not shifted: nil.
    public func applied(to date: Date?, calendar: Calendar = .current) -> Date? {
        switch self {
        case let .set(new): Self.wholeSeconds(new)
        case let .shift(shift): date.map { Self.wholeSeconds(shift.applied(to: $0, calendar: calendar)) }
        }
    }

    /// Capture dates stop at the second, in EXIF as in the sidecar.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }
}
