import Foundation

/// A month of a year, as the calendar of the user counts them.
public nonisolated struct YearMonth: Hashable, Comparable, Sendable {
    public var year: Int
    /// 1 to 12.
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 1)
    }

    /// The first instant of the month, for formatting its name.
    public func start(in calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

/// The months of a listing sorted by capture date: which rows each month holds. It is what the grid's
/// month headers, the month shown in the toolbar and the jump to a month are made of.
///
/// Built in one pass over the dates in listing order, whichever way they are sorted; photos without a
/// date form a section of their own, where the listing puts them. Sections never overlap and cover
/// every row. A month normally has one section; a listing that isn't sorted may bring it back later,
/// as another section (told apart by `Section.ID.occurrence`).
///
/// A source that reads its dates in the background can hand out a timeline of its first rows at
/// once: the rows not read yet are then one last section marked `isPending`.
public nonisolated struct DateTimeline: Hashable, Sendable {
    /// Consecutive rows of one month, or without a date.
    public struct Section: Hashable, Sendable, Identifiable {
        /// Stays the same when photos are added or removed elsewhere, unlike the rows.
        public struct ID: Hashable, Sendable {
            public var month: YearMonth?
            /// 0, unless the listing comes back to a month it had left.
            public var occurrence: Int
            public var isPending: Bool
        }

        /// Nil for the photos without a date, and for the rows whose dates aren't read yet.
        public var month: YearMonth?
        public var range: Range<Int>
        public var occurrence = 0
        /// True for the rows whose dates aren't read yet: nothing is known about them.
        public var isPending = false

        public var id: ID {
            ID(month: month, occurrence: occurrence, isPending: isPending)
        }
    }

    public private(set) var sections: [Section]

    /// Number of rows covered: the count of the listing it was built from.
    public var count: Int {
        sections.last?.range.upperBound ?? 0
    }

    public init(dates: some Sequence<Date?>, calendar: Calendar = .current) {
        var builder = Builder(calendar: calendar)
        for date in dates {
            builder.append(date)
        }
        self = builder.timeline
    }

    private init(sections: [Section]) {
        self.sections = sections
    }

    /// False while the dates of the last rows are still being read.
    public var isComplete: Bool {
        sections.last?.isPending != true
    }

    /// One section for a listing nothing is known about: every row, no month.
    public static func undated(count: Int) -> DateTimeline {
        DateTimeline(sections: count > 0 ? [Section(month: nil, range: 0 ..< count)] : [])
    }

    /// The section holding a row; nil past the end.
    public func section(containing index: Int) -> Section? {
        var low = 0
        var high = sections.count
        while low < high {
            let middle = (low + high) / 2
            if sections[middle].range.upperBound <= index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < sections.count, sections[low].range.contains(index) else { return nil }
        return sections[low]
    }

    /// The first section of a month in listing order; nil when the listing has no photo of that month.
    public func section(for month: YearMonth) -> Section? {
        sections.first { $0.month == month }
    }

    /// How many photos each month has.
    public var counts: [YearMonth: Int] {
        var counts: [YearMonth: Int] = [:]
        for section in sections {
            if let month = section.month {
                counts[month, default: 0] += section.range.count
            }
        }
        return counts
    }

    /// The years with photos, in listing order (newest first for a newest-first listing).
    public var years: [Int] {
        var years: [Int] = []
        for section in sections {
            if let year = section.month?.year, !years.contains(year) {
                years.append(year)
            }
        }
        return years
    }

    /// The same sections made to cover exactly `count` rows: cut short, or the last one extended.
    /// A listing can change a moment before its timeline is rebuilt; whoever lays rows out by section
    /// must never ask for a row that isn't there, nor leave one out.
    public func fitted(to count: Int) -> DateTimeline {
        guard count != self.count else { return self }
        guard count > 0 else { return DateTimeline(sections: []) }
        var fitted: [Section] = []
        for section in sections where section.range.lowerBound < count {
            var section = section
            section.range = section.range.lowerBound ..< min(section.range.upperBound, count)
            fitted.append(section)
        }
        guard var last = fitted.popLast() else { return .undated(count: count) }
        last.range = last.range.lowerBound ..< count
        fitted.append(last)
        return DateTimeline(sections: fitted)
    }

    /// Builds a timeline row by row, for listings read in batches. The calendar is only asked when a
    /// date leaves the month of the previous one: about once per month, not once per photo.
    public struct Builder {
        private let calendar: Calendar
        private var sections: [Section] = []
        private var count = 0
        /// The month of the section being filled and the instants it spans; nil for the undated section.
        private var current: (month: YearMonth?, interval: DateInterval?)?
        private var occurrences: [YearMonth?: Int] = [:]

        public init(calendar: Calendar = .current) {
            self.calendar = calendar
        }

        public mutating func append(_ date: Date?) {
            defer { count += 1 }
            if let current, isInCurrentSection(date, current) {
                sections[sections.count - 1].range = sections[sections.count - 1].range.lowerBound ..< count + 1
                return
            }
            let month = date.map { YearMonth($0, calendar: calendar) }
            let interval = date.flatMap { calendar.dateInterval(of: .month, for: $0) }
            let occurrence = occurrences[month, default: 0]
            occurrences[month] = occurrence + 1
            sections.append(Section(month: month, range: count ..< count + 1, occurrence: occurrence))
            current = (month, interval)
        }

        public var timeline: DateTimeline {
            DateTimeline(sections: sections)
        }

        /// The rows appended so far, then one pending section up to `count` for those still to read.
        public func timeline(pendingUpTo count: Int) -> DateTimeline {
            guard count > self.count else { return timeline }
            return DateTimeline(sections: sections + [Section(month: nil, range: self.count ..< count, isPending: true)])
        }

        private func isInCurrentSection(_ date: Date?, _ current: (month: YearMonth?, interval: DateInterval?)) -> Bool {
            guard let date else { return current.month == nil }
            guard let interval = current.interval else { return false }
            // A date interval includes its end, which is the first instant of the next month.
            return date >= interval.start && date < interval.end
        }
    }
}
