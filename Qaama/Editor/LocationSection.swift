import CoreLocation
import EditorKit
import ImageIOKit
import LibraryKit
import MapKit
import SwiftUI

/// The Location section of the Info panel, next to the grid and in the editor: the map of where the
/// photos were taken and, under it, the name of the place once Apple's geocoding service has told it.
/// The name is a footer rather than a row, so the map doesn't move when it arrives.
///
/// Where the source can store a location, Edit sets it for every photo shown: a place searched by
/// name, a click on the map, or the pin dragged elsewhere. The menu next to it removes the location,
/// or goes back to the one the file gives. Each change is one step in the Edit menu. Editing is a
/// mode of its own so that a click to look around the map never moves a photo; Image › Location ›
/// Assign Location… starts it from the menu bar (`LocationEditRequest`).
struct LocationSection: View {
    let source: any LibrarySource
    let assets: [LibraryAsset]

    @State private var model = LocationEditModel(search: PlaceSearch.apple)
    /// The name found, with the place it is for: a photo taken elsewhere doesn't keep the previous name.
    @State private var named: (location: GeoCoordinate, name: String)?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.locationEditRequest) private var request

    /// Whether the panel has a Location section for these photos: when one of them has a place, or
    /// when the source can give them one.
    static func isShown(for assets: [LibraryAsset], in source: any LibrarySource) -> Bool {
        source.capabilities.contains(.location) || assets.contains { source.location(for: $0) != nil }
    }

    private var canEdit: Bool {
        source.capabilities.contains(.location)
    }

    var body: some View {
        Section {
            content
        } header: {
            header
        } footer: {
            footer
        }
        .onChange(of: assets, initial: true) { _, assets in
            model.show(assets, in: source)
            // After `show`, which leaves the editing when the photos change: a menu that asked for
            // these photos may have changed the selection to them.
            takeRequest()
        }
        .onChange(of: request?.pending) { takeRequest() }
        .task(id: model.location) {
            guard let location = model.location,
                  let name = await PlaceNames.apple.name(for: location), !Task.isCancelled else { return }
            named = (location, name)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditing {
            searchField
            results
        }
        if model.isEditing || model.location != nil {
            map
        } else {
            unplaced
        }
        if let error = model.errorMessage {
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }

    private func takeRequest() {
        if request?.take(for: assets.map(\.id)) == true {
            model.isEditing = true
        }
    }

    private var searchField: some View {
        // Brought into view with the results and the map below it when it takes the keyboard: the
        // section is the last of the panel, often below its fold when the menu bar starts editing.
        SearchField(text: $model.query, prompt: "Search for a place", controlSize: .regular, revealedBelow: 260,
                    onMove: { offset in model.moveHighlight(by: offset) },
                    onSubmit: { Task { await model.pickHighlighted(undoManager: undoManager) } })
            .accessibilityLabel("Search for a place")
    }

    private var map: some View {
        let onPlace: ((GeoCoordinate) -> Void)? = model.isEditing ? { coordinate in place(coordinate) } : nil
        return LocationMap(location: model.location, focus: model.focus, onPlace: onPlace)
            .listRowInsets(EdgeInsets())
    }

    private var header: some View {
        HStack {
            Text("Location")
            Spacer()
            if canEdit, model.canRemove || model.canRevert {
                actionsMenu
            }
            // Without a place, the row below offers to assign one.
            if canEdit, model.isEditing || model.location != nil {
                Button(model.isEditing ? "Done" : "Edit") { model.isEditing.toggle() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(model.isEditing ? "Stop changing the location" : "Change where the photo was taken")
            }
        }
    }

    /// Remove Location and Revert to Original Location, as in Image › Location.
    private var actionsMenu: some View {
        Menu {
            Button("Remove Location") { Task { await model.remove(undoManager: undoManager) } }
                .disabled(!model.canRemove)
            if source.capabilities.contains(.originalLocation) {
                Button("Revert to Original Location") { Task { await model.revert(undoManager: undoManager) } }
                    .disabled(!model.canRevert)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Location actions")
        .accessibilityLabel("Location actions")
    }

    /// Sets the place a click or a drag of the pin chose.
    private func place(_ coordinate: GeoCoordinate) {
        Task { await model.assign(coordinate, undoManager: undoManager) }
    }

    /// Photos without a place, or with different ones.
    private var unplaced: some View {
        HStack {
            Text(model.isMixed ? "Several locations" : "No location")
                .foregroundStyle(.secondary)
            Spacer()
            if canEdit {
                Button("Assign…") { model.isEditing = true }
                    .controlSize(.small)
                    .help(model.isMixed ? "Give every selected photo the same location" : "Set where the photo was taken")
            }
        }
    }

    /// What the search found, while something is typed.
    @ViewBuilder
    private var results: some View {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            if model.suggestions.isEmpty {
                HStack(spacing: 6) {
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                    } else if model.errorMessage == nil {
                        Text("No places found")
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(model.suggestions) { suggestion in
                    PlaceSuggestionRow(suggestion: suggestion, isHighlighted: suggestion.id == model.highlightedID) {
                        Task { await model.pick(suggestion, undoManager: undoManager) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isEditing {
            Text(model.assets.count > 1
                ? "Search for a place or click the map: every selected photo goes there."
                : "Search for a place, click the map, or drag the pin.")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let location = model.location, let named, named.location == location {
            Text(named.name)
                .textSelection(.enabled)
                .accessibilityLabel("Place: \(named.name)")
        }
    }
}

/// One place found by the search: its name and, dimmed, where it is. Chosen by a click, or by
/// Return when highlighted (the arrow keys move the highlight from the search field).
private struct PlaceSuggestionRow: View {
    let suggestion: PlaceSuggestion
    let isHighlighted: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .lineLimit(1)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The colors of a selected row in a list that has the keyboard, as the system draws it.
            .foregroundStyle(isHighlighted ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
            .background(isHighlighted ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help([suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

extension PlaceNames {
    /// Place names from Apple's geocoding service, which is sent the position rounded to a hundred
    /// meters or so; one cache for the app's lifetime. Needs the outgoing network entitlement, as
    /// the map tiles do.
    static let apple = PlaceNames { coordinate in
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let item = try await MKReverseGeocodingRequest(location: location)?.mapItems.first else { return nil }
        let address = item.addressRepresentations
        return PlaceNames.compose(city: address?.cityName ?? address?.cityWithContext, region: address?.regionName, fallback: item.name)
    }
}

#Preview("Placed") {
    let source = SampleLibrarySource()
    Form {
        LocationSection(source: source, assets: [source.assets[0]])
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 320)
}

#Preview("Not placed") {
    let source = SampleLibrarySource()
    Form {
        LocationSection(source: source, assets: [source.assets[1]])
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 320)
}
