import LibraryKit
import SwiftUI

/// Where a grid is in time, and where it is asked to go: shared by the grid, which reports the month
/// at its top and scrolls on request, and by the toolbar's month button with its picker.
///
/// The grid writes what it shows only when it changes (another month, another day at either end),
/// not on every scroll frame, and never reads it: only the views showing the month or the dates are
/// updated while scrolling.
@Observable
final class TimelineNavigator {
    /// A request to bring a row to the top of the grid. The serial tells two requests for the same
    /// row apart: asking again for the month one scrolled away from must scroll back to it.
    struct Jump: Equatable {
        var row: Int
        var serial: Int
    }

    /// The section at the top of the grid; nil when the photos aren't sorted by date, or none is shown.
    private(set) var visibleSection: DateTimeline.Section.ID?
    /// The dates of the photos on screen, from the earliest to the latest, as text ("Oct 10 – Nov 2,
    /// 2021"); nil when the photos aren't sorted by date.
    private(set) var visibleDates: String?
    private(set) var jump: Jump?
    /// Whether the month picker is open, from the toolbar button or View › Go to Month.
    var isPickerPresented = false

    func go(to section: DateTimeline.Section) {
        jump = Jump(row: section.range.lowerBound, serial: (jump?.serial ?? 0) + 1)
    }

    /// Called by the grid as it scrolls.
    func gridShows(section: DateTimeline.Section.ID?, dates: ClosedRange<Date>?) {
        if section != visibleSection {
            visibleSection = section
        }
        // Compared as text: most scroll steps stay within the same days.
        let text = dates.map(MonthFormat.days)
        if text != visibleDates {
            visibleDates = text
        }
    }
}

/// How months are written in the grid's headers, the toolbar and the picker.
enum MonthFormat {
    /// "May 2017" in the headers and the picker.
    static func title(_ month: YearMonth) -> String {
        month.start()?.formatted(.dateTime.month(.wide).year()) ?? "\(month.month)/\(month.year)"
    }

    /// "May 2017" with a short month: the toolbar button keeps about the same width all year.
    static func shortTitle(_ month: YearMonth) -> String {
        month.start()?.formatted(.dateTime.month(.abbreviated).year()) ?? "\(month.month)/\(month.year)"
    }

    /// The title of a section of the grid; nil for the rows whose dates aren't read yet.
    static func title(_ section: DateTimeline.Section.ID) -> String? {
        if section.isPending {
            return nil
        }
        return section.month.map(title) ?? undated
    }

    static let undated = "No Date"

    /// "Oct 10 – Nov 2, 2021", or one day when both ends fall on it, as the system writes intervals.
    static func days(_ dates: ClosedRange<Date>) -> String {
        if Calendar.current.isDate(dates.lowerBound, inSameDayAs: dates.upperBound) {
            return dates.lowerBound.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return (dates.lowerBound ..< dates.upperBound).formatted(.interval.day().month(.abbreviated).year())
    }
}

/// What View › Go to Month… does in the key window: open the month picker of its grid. Absent when
/// the window shows no grid, or its photos aren't sorted by date.
struct GoToMonthAction {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

struct FocusedGoToMonthKey: FocusedValueKey {
    typealias Value = GoToMonthAction
}

extension FocusedValues {
    var goToMonthAction: GoToMonthAction? {
        get { self[FocusedGoToMonthKey.self] }
        set { self[FocusedGoToMonthKey.self] = newValue }
    }
}
