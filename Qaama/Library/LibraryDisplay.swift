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
