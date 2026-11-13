import SwiftUI

/// What the detail column shows of a library: its thumbnails, or where its photos were taken. Lives
/// in the preferences under `key`, read with `@AppStorage` by the window and the View menu alike;
/// a library without places shows its grid whatever it says.
enum LibraryDisplay: String, CaseIterable {
    case grid
    case map

    static let key = "libraryDisplay"
}

/// View › as Grid and as Map in the key window: what it shows now and how to change it. Absent
/// (the commands are disabled) in the editor and for libraries without places.
struct LibraryDisplayAction {
    let current: LibraryDisplay
    let show: (LibraryDisplay) -> Void
}

struct FocusedLibraryDisplayKey: FocusedValueKey {
    typealias Value = LibraryDisplayAction
}

extension FocusedValues {
    var libraryDisplayAction: LibraryDisplayAction? {
        get { self[FocusedLibraryDisplayKey.self] }
        set { self[FocusedLibraryDisplayKey.self] = newValue }
    }
}

/// View › Zoom In and Zoom Out in a window showing the map. The map stops by itself at the ends of
/// its range, so the commands stay enabled.
struct MapZoomAction {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
}

struct FocusedMapZoomKey: FocusedValueKey {
    typealias Value = MapZoomAction
}

extension FocusedValues {
    var mapZoomAction: MapZoomAction? {
        get { self[FocusedMapZoomKey.self] }
        set { self[FocusedMapZoomKey.self] = newValue }
    }
}

/// The toolbar's switch between the grid and the map; the View menu holds the same choice.
struct LibraryDisplayPicker: View {
    @Binding var display: LibraryDisplay

    var body: some View {
        Picker("View", selection: $display) {
            Label("Grid", systemImage: "square.grid.2x2")
                .help("Show the photos as a grid")
                .tag(LibraryDisplay.grid)
            Label("Map", systemImage: "map")
                .help("Show the photos on a map")
                .tag(LibraryDisplay.map)
        }
        .pickerStyle(.segmented)
        .help("Show the photos as a grid or on a map")
    }
}

/// How the map of a library is drawn: Apple's standard map, or satellite imagery with the names of
/// places over it. In the preferences under `key`, shared by the map, its toolbar button and the
/// View menu.
enum LibraryMapStyle: String, CaseIterable {
    case standard
    case satellite

    static let key = "libraryMapStyle"
}

/// The toolbar's satellite button, next to the map; the same preference as View › Map Style.
struct SatelliteToggle: View {
    @AppStorage(LibraryMapStyle.key) private var style = LibraryMapStyle.standard

    var body: some View {
        Toggle(isOn: Binding(get: { style == .satellite }, set: { style = $0 ? .satellite : .standard })) {
            Label("Satellite", systemImage: "globe.europe.africa")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help(style == .satellite ? "Show the standard map" : "Show satellite imagery")
    }
}
