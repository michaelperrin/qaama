import EditorKit
import ImageIOKit
import LibraryKit
import SwiftUI

/// The toolbar's Filter button: filled while filters apply, it opens the Filter panel.
struct FilterButton: View {
    let source: any LibrarySource
    let panels: LibraryFilterPanels
    /// Saving the panel's settings as a preset, and updating the one on screen; nil where presets
    /// can't be saved.
    var presets: FilterPresetSaving?
    @State private var isPresented = false

    var body: some View {
        let isFiltered = !source.query.filters.isEmpty
        Button {
            isPresented.toggle()
        } label: {
            Label("Filter", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(isFiltered ? "Filters (some apply)" : "Filters")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FilterPanel(source: source, panels: panels, presets: presets.map { presets in
                var closing = presets
                closing.saveAsNew = { settings in
                    // The name is asked by the window, once the panel is out of the way.
                    isPresented = false
                    presets.saveAsNew(settings)
                }
                return closing
            })
        }
    }
}

/// The filters of a library, one row each: a checkbox says whether the filter applies, and the row
/// of a checked filter shows what it asks (stars, a flag, dates, a place and a radius). The switch
/// at the top turns them all off without losing them; the arrow next to it unchecks everything.
/// Rows the library can't answer are left out. The principle is Photomator's Filter panel.
/// At the bottom, Save as Preset… keeps the filters that apply as an entry of the sidebar; in a
/// preset, the button updates it instead, and its menu saves a new one.
///
/// What the panel shows lives in `LibraryFilterPanels`, which asks the library as it changes.
struct FilterPanel: View {
    let source: any LibrarySource
    let panels: LibraryFilterPanels
    /// Saving these settings as a preset and updating the one on screen; nil (no button) where
    /// presets can't be saved.
    var presets: FilterPresetSaving?

    /// The search for the center of the place filter.
    @State private var places = PlaceSearchModel(search: PlaceSearch.apple)
    /// The radius while its slider moves: the library is only asked once it rests.
    @State private var draftRadius: Double?
    /// The name of a place picked on the map, with the place it is for.
    @State private var named: (place: GeoCoordinate, name: String)?
    /// The span of time last chosen, for the Date row to come back to after two days were shown.
    @State private var lastSpan = RelativeDateSpan(30, .days)

    private static let width: CGFloat = 320

    private var settings: Binding<LibraryFilterSettings> {
        Binding(get: { panels.settings(for: source) }, set: { panels.set($0, for: source) })
    }

    var body: some View {
        let supports = source.queryCapabilities
        let settings = settings
        VStack(alignment: .leading, spacing: 0) {
            header(settings)
            VStack(alignment: .leading, spacing: 0) {
                if supports.contains(.favorite) {
                    FilterRow("Favorites", symbol: "heart", isOn: settings.favoritesOnly)
                }
                if supports.contains(.edited) {
                    FilterRow("Edits", symbol: "slider.horizontal.3", isOn: settings.editedOnly) {
                        Picker("Edits", selection: Binding(get: { settings.wrappedValue.edits ?? .edited }, set: { settings.wrappedValue.edits = $0 })) {
                            Text("Edited").tag(EditsFilter.edited)
                            Text("Not Edited").tag(EditsFilter.notEdited)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if supports.contains(.raw) {
                    FilterRow("RAW", symbol: "r.square", isOn: settings.rawOnly)
                }
                if supports.contains(.rating) {
                    FilterRow("Rating", symbol: "star", isOn: settings.filtersRating) {
                        ratingPickers(settings.rating)
                    }
                }
                if supports.contains(.flag) {
                    FilterRow("Flag", symbol: "flag", isOn: settings.filtersFlag) {
                        flagPicker(settings.flag)
                    }
                }
                if supports.contains(.captureDates) {
                    FilterRow("Date", symbol: "calendar", isOn: settings.filtersDates) {
                        datesKindPicker(settings.relativeDates)
                    } detail: {
                        dates(settings)
                    }
                }
                if supports.contains(.place) {
                    FilterRow("Location", symbol: "mappin.and.ellipse", isOn: settings.filtersPlace) {
                        placeName(settings.wrappedValue)
                    } detail: {
                        place(settings)
                    }
                }
            }
            .disabled(!settings.wrappedValue.isEnabled)
            if supports.contains(.pairedJPEGs) {
                Divider()
                // Not a filter: what a RAW + JPEG pair shows as, whatever the switch above says.
                Toggle("Show JPEG Twins of RAW Files", isOn: Binding(get: { source.query.includesPairedJPEGs },
                                                                     set: { source.query.includesPairedJPEGs = $0 }))
                    .padding(.vertical, FilterRow<EmptyView, EmptyView>.padding)
            }
            if let presets {
                Divider()
                HStack {
                    Spacer()
                    presetButton(presets, settings.wrappedValue)
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .task(id: settings.wrappedValue.place) {
            guard let place = settings.wrappedValue.place, settings.wrappedValue.placeName.isEmpty,
                  let name = await PlaceNames.apple.name(for: place), !Task.isCancelled else { return }
            named = (place, name)
        }
        // A slider moved from the keyboard never says it is let go: a pause commits as well.
        .task(id: draftRadius) {
            guard draftRadius != nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled {
                commitRadius()
            }
        }
    }

    private func header(_ settings: Binding<LibraryFilterSettings>) -> some View {
        HStack(spacing: 10) {
            Text("Filter")
                .font(.headline)
            Spacer()
            Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                places.query = ""
                draftRadius = nil
                settings.wrappedValue = LibraryFilterSettings()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!settings.wrappedValue.hasChoices)
            .help("Uncheck every filter")
            Toggle("Apply Filters", isOn: settings.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(settings.wrappedValue.isEnabled ? "Turn the filters off, keeping them as they are" : "Turn the filters back on")
        }
        .padding(.vertical, FilterRow<EmptyView, EmptyView>.padding)
    }

    // MARK: - Presets

    /// Save as Preset…, or in a preset the system's split button: Update Preset, with Save as New
    /// Preset… under its arrow. A preset that filters nothing would only show the library again,
    /// and one that already says what the panel shows has nothing to update.
    @ViewBuilder
    private func presetButton(_ presets: FilterPresetSaving, _ settings: LibraryFilterSettings) -> some View {
        let filtersNothing = source.query.filters.isEmpty
        if let shown = presets.shown {
            Menu {
                Button("Save as New Preset…") { presets.saveAsNew(settings) }
            } label: {
                Text("Update Preset")
            } primaryAction: {
                presets.update(settings)
            }
            .fixedSize()
            .disabled(filtersNothing || settings.asksTheSame(as: shown.settings))
            .help("Replace the filters of “\(shown.name)” with these")
        } else {
            Button("Save as Preset…") { presets.saveAsNew(settings) }
                .disabled(filtersNothing)
                .help("Keep these filters in the sidebar, for this library")
        }
    }

    // MARK: - Rating and flag

    private func ratingPickers(_ rating: Binding<RatingFilter>) -> some View {
        HStack(spacing: 6) {
            Picker("Comparison", selection: rating.comparison) {
                Text("At Least").tag(RatingFilter.Comparison.atLeast)
                Text("At Most").tag(RatingFilter.Comparison.atMost)
                Text("Exactly").tag(RatingFilter.Comparison.exactly)
            }
            .help("How the photos' rating compares to the stars")
            Picker("Stars", selection: rating.stars) {
                ForEach((1 ... 5).reversed(), id: \.self) { stars in
                    Text(String(repeating: "★", count: stars))
                        .accessibilityLabel(stars == 1 ? "1 star" : "\(stars) stars")
                        .tag(stars)
                }
                Divider()
                Text("Unrated").tag(0)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func flagPicker(_ flag: Binding<FlagFilter>) -> some View {
        Picker("Flag", selection: flag) {
            Text("Picked").tag(FlagFilter.picked)
            Text("Rejected").tag(FlagFilter.rejected)
            Text("Unflagged").tag(FlagFilter.unflagged)
            Divider()
            Text("Not Rejected").tag(FlagFilter.notRejected)
        }
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Dates

    /// Whether the dates are two days, which stay put, or a span of time ending today, which
    /// moves on with the days.
    private func datesKindPicker(_ span: Binding<RelativeDateSpan?>) -> some View {
        Picker("Dates", selection: Binding(get: { span.wrappedValue != nil }, set: { isRelative in
            if let current = span.wrappedValue {
                lastSpan = current
            }
            span.wrappedValue = isRelative ? lastSpan : nil
        })) {
            Text("Between").tag(false)
            Text("In the Last").tag(true)
        }
        .labelsHidden()
        .fixedSize()
        .help("Between two days, or a length of time back from today")
    }

    @ViewBuilder
    private func dates(_ settings: Binding<LibraryFilterSettings>) -> some View {
        if let span = settings.wrappedValue.relativeDates {
            let amount = Binding(get: { span.amount }, set: { amount in
                let range = RelativeDateSpan.amountRange
                settings.wrappedValue.relativeDates?.amount = min(max(amount, range.lowerBound), range.upperBound)
            })
            HStack(spacing: 8) {
                TextField("Amount", value: amount, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Stepper("Amount", value: amount, in: RelativeDateSpan.amountRange)
                Picker("Unit", selection: Binding(get: { span.unit }, set: { settings.wrappedValue.relativeDates?.unit = $0 })) {
                    Text(span.amount == 1 ? "Day" : "Days").tag(RelativeDateSpan.Unit.days)
                    Text(span.amount == 1 ? "Week" : "Weeks").tag(RelativeDateSpan.Unit.weeks)
                    Text(span.amount == 1 ? "Month" : "Months").tag(RelativeDateSpan.Unit.months)
                    Text(span.amount == 1 ? "Year" : "Years").tag(RelativeDateSpan.Unit.years)
                }
                .fixedSize()
            }
            .labelsHidden()
        } else {
            HStack(spacing: 8) {
                DatePicker("From", selection: settings.firstDay, displayedComponents: .date)
                Text("to")
                    .foregroundStyle(.secondary)
                DatePicker("To", selection: settings.lastDay, displayedComponents: .date)
            }
            .datePickerStyle(.stepperField)
            .labelsHidden()
        }
    }

    // MARK: - Place

    /// The place filtered by, at the end of its row: the name it was found under, or the one of the
    /// point picked on the map once Apple's geocoding service has told it.
    @ViewBuilder
    private func placeName(_ settings: LibraryFilterSettings) -> some View {
        if let place = settings.place {
            let name = settings.placeName.isEmpty ? (named?.place == place ? named?.name : nil) : settings.placeName
            Text(name ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func place(_ settings: Binding<LibraryFilterSettings>) -> some View {
        let center = settings.wrappedValue.place
        // Typed in at once when there is no place yet: that is what checking the box calls for.
        SearchField(text: $places.query, prompt: "Search for a place", controlSize: .small, takesKeyboard: center == nil,
                    onMove: { offset in places.moveHighlight(by: offset) },
                    onSubmit: {
                        if let suggestion = places.highlighted {
                            pick(suggestion, settings)
                        }
                    })
                    .accessibilityLabel("Search for a place")
        PlaceSearchResults(search: places) { suggestion in pick(suggestion, settings) }
        if let error = places.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red)
        }
        if center == nil {
            Text("Search for a place, or click the map.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            radius(settings)
        }
        PlaceFilterMap(center: center, radius: draftRadius ?? settings.wrappedValue.radius, framedRadius: settings.wrappedValue.radius) { coordinate in
            places.near = coordinate
            settings.wrappedValue.placeName = ""
            settings.wrappedValue.place = coordinate
        }
    }

    private func pick(_ suggestion: PlaceSuggestion, _ settings: Binding<LibraryFilterSettings>) {
        places.query = ""
        places.near = suggestion.coordinate
        settings.wrappedValue.placeName = suggestion.title
        settings.wrappedValue.place = suggestion.coordinate
    }

    /// The radius as a slider, even steps of which multiply it (a kilometer matters near 5, not
    /// near 500), and as a number to type.
    private func radius(_ settings: Binding<LibraryFilterSettings>) -> some View {
        let range = LibraryFilterSettings.radiusRange
        let shown = draftRadius ?? settings.wrappedValue.radius
        let unit = RadiusUnit.showing(shown)
        return HStack(spacing: 8) {
            Slider(value: Binding(get: { log10(shown) }, set: { draftRadius = RadiusUnit.rounded(pow(10, $0)) }),
                   in: log10(range.lowerBound) ... log10(range.upperBound))
            { isEditing in
                if !isEditing {
                    commitRadius()
                }
            }
            .accessibilityLabel("Radius")
            // Typed in the unit shown: 5000 typed next to "m" comes back as 5 km.
            TextField("Radius", value: Binding(get: { (shown / unit.meters).rounded() },
                                               set: { settings.wrappedValue.radius = min(max($0 * unit.meters, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0)))
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .labelsHidden()
            Text(unit.symbol)
                .foregroundStyle(.secondary)
        }
        .help("How far from the place the photos may have been taken")
    }

    private func commitRadius() {
        guard let draftRadius else { return }
        self.draftRadius = nil
        if settings.wrappedValue.radius != draftRadius {
            settings.wrappedValue.radius = draftRadius
        }
    }
}

/// One filter of the panel: its checkbox and, while it is checked, what it asks: a control at the
/// end of the row, more below it. Every row is as tall checked as unchecked, so checking a box
/// doesn't move the ones under it.
private struct FilterRow<Accessory: View, Detail: View>: View {
    static var padding: CGFloat {
        7
    }

    private static var symbolWidth: CGFloat {
        18
    }

    private let title: LocalizedStringKey
    private let symbol: String
    @Binding private var isOn: Bool
    private let accessory: Accessory
    private let detail: Detail

    init(_ title: LocalizedStringKey, symbol: String, isOn: Binding<Bool>, @ViewBuilder accessory: () -> Accessory, @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.symbol = symbol
        _isOn = isOn
        self.accessory = accessory()
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle(isOn: $isOn) {
                        Label {
                            Text(title)
                        } icon: {
                            // Symbols are of different widths: the titles line up all the same.
                            Image(systemName: symbol)
                                .frame(width: Self.symbolWidth)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                    if isOn {
                        accessory
                    }
                }
                .frame(minHeight: 20)
                if isOn {
                    detail
                }
            }
            .padding(.vertical, Self.padding)
        }
    }
}

extension FilterRow where Detail == EmptyView {
    init(_ title: LocalizedStringKey, symbol: String, isOn: Binding<Bool>, @ViewBuilder accessory: () -> Accessory) {
        self.init(title, symbol: symbol, isOn: isOn, accessory: accessory) { EmptyView() }
    }
}

extension FilterRow where Accessory == EmptyView, Detail == EmptyView {
    init(_ title: LocalizedStringKey, symbol: String, isOn: Binding<Bool>) {
        self.init(title, symbol: symbol, isOn: isOn) { EmptyView() }
    }
}

/// The unit a radius is shown and typed in: kilometers, or miles where roads are measured in them,
/// and meters or feet for a radius shorter than one of those.
private struct RadiusUnit {
    let meters: Double
    let symbol: String
    /// What the slider moves by, in this unit, for radii up to a number of them.
    let steps: [(upTo: Double, step: Double)]

    private static let kilometers = RadiusUnit(meters: 1000, symbol: "km", steps: [(100, 1), (.infinity, 10)])
    private static let miles = RadiusUnit(meters: 1609.344, symbol: "mi", steps: [(100, 1), (.infinity, 10)])
    private static let smallMeters = RadiusUnit(meters: 1, symbol: "m", steps: [(200, 10), (.infinity, 50)])
    private static let feet = RadiusUnit(meters: 0.3048, symbol: "ft", steps: [(1000, 50), (.infinity, 100)])

    /// The unit a radius in meters reads best in, for the user's region.
    static func showing(_ radius: Double) -> RadiusUnit {
        let (large, small) = Locale.current.measurementSystem == .metric ? (kilometers, smallMeters) : (miles, feet)
        // Half a step short of the large unit already rounds to one of it.
        return radius < large.meters * 0.975 ? small : large
    }

    /// A radius in meters as the nearest round number of the unit it shows in: tens of meters, then
    /// fifties; whole kilometers, then tens beyond a hundred.
    static func rounded(_ radius: Double) -> Double {
        let unit = showing(radius)
        let units = radius / unit.meters
        let step = unit.steps.first { units < $0.upTo }?.step ?? 1
        let range = LibraryFilterSettings.radiusRange
        return min(max((units / step).rounded() * step * unit.meters, range.lowerBound), range.upperBound)
    }
}

#Preview("Filter panel") {
    @Previewable @State var panels = LibraryFilterPanels()
    FilterPanel(source: SampleLibrarySource(), panels: panels)
}
