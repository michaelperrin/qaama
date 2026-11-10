import LibraryKit
import SwiftUI

/// The toolbar's month button: shows the month at the top of the grid and opens the month picker.
/// Disabled when the photos aren't sorted by capture date, the only order in which a month is a place
/// in the grid.
struct MonthButton: View {
    @Bindable var navigator: TimelineNavigator
    let timeline: DateTimeline?

    var body: some View {
        Button {
            navigator.isPickerPresented.toggle()
        } label: {
            // A steady width: the other toolbar items mustn't shift as the months go by.
            Text(title)
                .monospacedDigit()
                .frame(minWidth: 76)
        }
        .disabled(!isAvailable)
        .help(help)
        .accessibilityLabel(isAvailable ? "Go to Month, showing \(title)" : "Go to Month")
        .popover(isPresented: $navigator.isPickerPresented, arrowEdge: .bottom) {
            if let timeline {
                MonthPicker(timeline: timeline, current: navigator.visibleSection?.month) { section in
                    navigator.go(to: section)
                }
            }
        }
    }

    /// The picker needs every month: it waits for the dates still being read (a second or two).
    private var isAvailable: Bool {
        timeline.map { $0.isComplete && !$0.sections.isEmpty } ?? false
    }

    private var title: String {
        guard timeline != nil, let section = navigator.visibleSection, !section.isPending else { return "Months" }
        return section.month.map(MonthFormat.shortTitle) ?? MonthFormat.undated
    }

    private var help: String {
        guard let timeline else { return "Sort by capture date to browse by month" }
        return timeline.isComplete ? "Go to a month" : "Reading the dates of the photos…"
    }
}

/// Picks a month to go to: the years with photos in a column, and the twelve months of the year
/// chosen there. Clicking a year scrolls the grid to it and shows its months; clicking a month scrolls
/// to that month. The picker stays open, to try the month next to it.
///
/// Deliberately quiet. Two earlier versions showed every month of every year at once: as cells shaded
/// by their number of photos with the number in them ("assez violent visuellement"), then as rows of
/// month names, where "Jan Feb Mar…" repeated on every line was disturbing (Michaël, 2026-11-10).
/// Month names are now written once; the number of photos is told below, for the month under the
/// pointer.
struct MonthPicker: View {
    let timeline: DateTimeline
    /// The month at the top of the grid, highlighted.
    let current: YearMonth?
    let onPick: (DateTimeline.Section) -> Void

    /// The year whose months are shown: the one on screen at first, then the one clicked.
    @State private var chosenYear: Int?
    @State private var hoveredMonth: Int?
    @State private var hoveredYear: Int?

    private static let cellSize = CGSize(width: 64, height: 32)
    private static let spacing: CGFloat = 4
    private static let yearSize = CGSize(width: 64, height: 24)
    private static let monthsHeight = 4 * cellSize.height + 3 * spacing

    var body: some View {
        let counts = timeline.counts
        let years = timeline.years
        let year = chosenYear ?? current?.year ?? years.first
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(years, id: \.self) { listed in
                                yearRow(listed, isChosen: listed == year)
                                    .id(listed)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The year on screen may be far down a long list.
                    .onAppear { proxy.scrollTo(year, anchor: .center) }
                }
                .frame(width: Self.yearSize.width, height: Self.monthsHeight)
                Divider()
                    .frame(height: Self.monthsHeight)
                Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                    ForEach(0 ..< 4, id: \.self) { row in
                        GridRow {
                            ForEach(1 ... 3, id: \.self) { column in
                                monthCell(row * 3 + column, year: year, counts: counts)
                            }
                        }
                    }
                }
            }
            Divider()
            Text(caption(year: year, counts: counts))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .fixedSize()
    }

    private func yearRow(_ year: Int, isChosen: Bool) -> some View {
        Button {
            chosenYear = year
            hoveredMonth = nil
            if let section = timeline.sections.first(where: { $0.month?.year == year }) {
                onPick(section)
            }
        } label: {
            Text(String(year))
                .font(.callout.weight(isChosen ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: Self.yearSize.width, height: Self.yearSize.height)
                .background {
                    if isChosen || year == hoveredYear {
                        RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(isChosen ? 1 : 0.5))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredYear = year
            } else if hoveredYear == year {
                hoveredYear = nil
            }
        }
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    @ViewBuilder
    private func monthCell(_ month: Int, year: Int?, counts: [YearMonth: Int]) -> some View {
        let yearMonth = year.map { YearMonth(year: $0, month: month) }
        let count = yearMonth.flatMap { counts[$0] } ?? 0
        let isCurrent = yearMonth != nil && yearMonth == current
        Button {
            if let yearMonth, let section = timeline.section(for: yearMonth) {
                onPick(section)
            }
        } label: {
            Text(Self.monthSymbols[month - 1])
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(count > 0 ? .primary : .quaternary))
                .frame(width: Self.cellSize.width, height: Self.cellSize.height)
                .background {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                    } else if month == hoveredMonth, count > 0 {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .onHover { inside in
            if inside {
                hoveredMonth = month
            } else if hoveredMonth == month {
                hoveredMonth = nil
            }
        }
        .accessibilityLabel(yearMonth.map { count > 0 ? "\(MonthFormat.title($0)), \(count) photos" : "\(MonthFormat.title($0)), no photos" } ?? "")
    }

    /// The month under the pointer, else the month the grid shows when it is in the year chosen,
    /// else that year as a whole.
    private func caption(year: Int?, counts: [YearMonth: Int]) -> String {
        guard let year else { return "No photos" }
        let month = hoveredMonth.map { YearMonth(year: year, month: $0) } ?? (current?.year == year ? current : nil)
        if let month, let count = counts[month] {
            return "\(MonthFormat.title(month)) · \(Self.photos(count))"
        }
        return "\(String(year)) · \(Self.photos(counts.filter { $0.key.year == year }.values.reduce(0, +)))"
    }

    private static func photos(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "photo" : "photos")"
    }

    /// "Jan", "Feb"… as the user's calendar writes them.
    private static let monthSymbols: [String] = {
        let symbols = Calendar.current.shortStandaloneMonthSymbols
        return symbols.count == 12 ? symbols : (1 ... 12).map(String.init)
    }()
}

#Preview("Month picker") {
    // Twelve years of photos, unevenly spread: more in summer, a few empty months.
    let calendar = Calendar.current
    let dates: [Date?] = (0 ..< 144).reversed().flatMap { offset -> [Date?] in
        let month = offset % 12 + 1
        let count = offset % 7 == 3 ? 0 : (month == 7 || month == 8 ? 900 : 40 + offset * 3) + (offset == 113 ? 2600 : 0)
        let date = calendar.date(from: DateComponents(year: 2015 + offset / 12, month: month, day: 15))
        return Array(repeating: date, count: count)
    }
    MonthPicker(timeline: DateTimeline(dates: dates), current: YearMonth(year: 2017, month: 5)) { _ in }
}
