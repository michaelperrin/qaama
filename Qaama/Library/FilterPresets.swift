import LibraryKit
import SwiftUI

/// What the Filter panel can do with presets in this window, with the settings it shows. Absent
/// where the library on screen can't have presets: the map of every library, previews.
struct FilterPresetSaving {
    /// The preset on screen, when the window shows one: the panel then offers to update it.
    var shown: FilterPreset?
    /// Asks a name, then saves the settings as a new preset of the library on screen.
    var saveAsNew: (LibraryFilterSettings) -> Void
    /// Replaces what the preset on screen filters by, as one undoable step.
    var update: (LibraryFilterSettings) -> Void
}

extension EnvironmentValues {
    @Entry var filterPresetSaving: FilterPresetSaving?
    /// The name a library's window goes by instead of the library's own: a preset's. Nil elsewhere.
    @Entry var libraryTitle: String?
}

/// A filter preset waiting for its name: one being saved, for a library and from the panel's
/// settings, or one being renamed.
enum FilterPresetDialog: Equatable {
    case new(FilterPreset.Library, LibraryFilterSettings)
    case rename(FilterPreset)

    fileprivate var initialName: String {
        switch self {
        case .new: "Untitled Filter"
        case let .rename(preset): preset.name
        }
    }
}

extension View {
    /// Asks the name of the preset set in `dialog`, then saves or renames it as one undoable step.
    func filterPresetDialog(_ dialog: Binding<FilterPresetDialog?>, store: FilterPresetStore) -> some View {
        modifier(FilterPresetDialogs(dialog: dialog, store: store))
    }
}

private struct FilterPresetDialogs: ViewModifier {
    @Binding var dialog: FilterPresetDialog?
    let store: FilterPresetStore

    @State private var name = ""
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { dialog != nil }, set: {
                if !$0 {
                    dialog = nil
                }
            }), presenting: dialog) { asked in
                TextField("Name", text: $name)
                switch asked {
                case let .new(library, settings):
                    Button("Save") { store.add(named: name, library: library, settings: settings, undoManager: undoManager) }
                case let .rename(preset):
                    Button("Rename") { store.rename(preset.id, to: name, undoManager: undoManager) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { asked in
                if case .new = asked {
                    Text("The preset is added to the sidebar: it shows this library with these filters.")
                }
            }
            .onChange(of: dialog) { _, dialog in
                if let dialog {
                    name = dialog.initialName
                }
            }
    }

    private var title: String {
        if case .rename = dialog {
            return "Rename Filter Preset"
        }
        return "Save Filters as Preset"
    }
}

/// The detail column of a filter preset: its library, in a view that is the preset's own, filtered
/// as the preset was saved. The filters can be changed while looking, in the Filter panel, which
/// then offers to update the preset; coming back to the preset shows it as saved again.
struct FilterPresetView: View {
    let preset: FilterPreset
    let catalog: LibraryCatalog
    var maps: PhotoMapModels?

    @Environment(LibraryFilterPanels.self) private var panels: LibraryFilterPanels?

    var body: some View {
        let library = catalog.library(for: preset)
        Group {
            switch library {
            case let .photos(source):
                PhotosLibraryView(source: source, albums: catalog.photosAlbums, albumEditor: catalog.photosAlbumEditor, maps: maps)
            case let .folder(view, scannedBy, path):
                FolderLibraryView(source: view, path: path, maps: maps)
                    // The view only follows the catalog: the folder's own source lists and watches it.
                    .task { await scannedBy.load() }
            case nil:
                if isWaitingForAlbums {
                    ProgressView("Loading albums…")
                        .task {
                            let access = await PhotoLibraryAccess.request()
                            if access == .authorized || access == .limited {
                                catalog.photosAlbums.load()
                            }
                        }
                } else {
                    ContentUnavailableView("Library Unavailable", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("The album or folder “\(preset.name)” was saved for is no longer there."))
                }
            }
        }
        .environment(\.libraryTitle, preset.name)
        // Shown as saved each time the preset is come to, and once its album is listed.
        .onChange(of: library != nil, initial: true) {
            if let source = catalog.library(for: preset)?.source {
                panels?.set(preset.settings, for: source)
            }
        }
    }

    /// An album's preset can't tell whether its album is still there until the albums are listed.
    private var isWaitingForAlbums: Bool {
        if case .photosAlbum = preset.library {
            return !catalog.photosAlbums.isLoaded && PhotoLibraryAccess.current != .denied
        }
        return false
    }
}
