import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Which library the sidebar shows in the detail column.
enum LibrarySelection: Hashable {
    /// The map of the Photos library and every folder together.
    case map
    case photos
    case photosAlbum(PhotosAlbum.ID)
    case folder(FolderLibrarySource.ID)
    /// A subdirectory of a folder, by relative path.
    case subfolder(FolderLibrarySource.ID, String)
    /// A library filtered as a preset says.
    case filterPreset(FilterPreset.ID)

    /// The sidebar's entry of the library a preset filters.
    init(_ library: FilterPreset.Library) {
        switch library {
        case .photos: self = .photos
        case let .photosAlbum(id): self = .photosAlbum(id)
        case let .folder(id, path): self = path.map { .subfolder(id, $0) } ?? .folder(id)
        }
    }
}

extension LibraryCatalog {
    /// The name the sidebar shows for a library.
    func title(of location: LibrarySelection) -> String {
        switch location {
        case .map: "Map"
        case .photos: "Photos"
        case let .photosAlbum(id): photosAlbums.album(id: id)?.title ?? "Album"
        case let .folder(id): folders.first { $0.id == id }?.displayName ?? "Folder"
        case let .subfolder(_, path): path.split(separator: "/").last.map(String.init) ?? "Folder"
        case let .filterPreset(id): filterPresets.preset(id: id)?.name ?? "Filter Preset"
        }
    }
}

/// Sidebar of libraries on the left, the selected library's grid on the right.
struct MainWindowView: View {
    let catalog: LibraryCatalog
    @State private var selection: LibrarySelection? = .photos
    @State private var isPickingFolder = false
    @State private var folderError: String?
    /// The map of each library shown on one, kept while the sidebar goes elsewhere.
    @State private var maps = PhotoMapModels()
    /// Whether the sidebar is shown, for its toggle to tell.
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// The albums opened from an Info panel, one from the other, and how each library was left.
    @State private var trail = VisitTrail<LibrarySelection, LibraryPlace>()
    /// The place to put a library back in, between Back and the library's view showing.
    @State private var arrival = LibraryArrival()
    /// The filter preset being named: one saved from the Filter panel, or one renamed in the sidebar.
    @State private var presetDialog: FilterPresetDialog?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(catalog: catalog, selection: $selection, visibility: $columnVisibility, presetDialog: $presetDialog,
                        addFolder: { isPickingFolder = true })
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
                // Albums named in an Info panel open through the sidebar's selection, with a way back.
                .environment(\.libraryVisits, LibraryVisits(albums: catalog.photosAlbums, currentAlbumID: currentAlbumID, arrival: arrival,
                                                            back: backAction, open: openAlbum))
                .environment(\.filterPresetSaving, presetLibrary.map { library in
                    let shown = shownPreset
                    return FilterPresetSaving(shown: shown, saveAsNew: { settings in presetDialog = .new(library, settings) }, update: { settings in
                        if let shown {
                            catalog.filterPresets.update(shown.id, settings: settings, undoManager: undoManager)
                        }
                    })
                })
        }
        .filterPresetDialog($presetDialog, store: catalog.filterPresets)
        .onChange(of: selection) { _, location in
            // The sidebar was used: there is nothing to go back to any more.
            if let location {
                trail.moved(to: location)
            } else {
                trail = VisitTrail()
            }
            arrival.moved(to: location)
        }
        .task { await catalog.load() }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            Task { await addFolder(result) }
        }
        .alert("Couldn't Add Folder", isPresented: Binding(get: { folderError != nil }, set: {
            if !$0 {
                folderError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderError ?? "")
        }
    }

    private var currentAlbumID: PhotosAlbum.ID? {
        if case let .photosAlbum(id) = selection {
            return id
        }
        return nil
    }

    /// Shows an album named in an Info panel, keeping the way back to what is on screen.
    private func openAlbum(_ id: PhotosAlbum.ID, leaving place: LibraryPlace) {
        guard let origin = selection else { return }
        trail.visit(.photosAlbum(id), from: origin, leaving: place)
        selection = .photosAlbum(id)
    }

    /// Back to where the album on screen was opened from, as it was left; nil when it was chosen
    /// in the sidebar.
    private var backAction: BackAction? {
        guard let selection, let origin = trail.origin(of: selection) else { return nil }
        return BackAction(help: "Back to “\(catalog.title(of: origin))”") {
            guard let back = trail.goBack(from: selection) else { return }
            arrival.expect(back.place, at: back.origin)
            self.selection = back.origin
        }
    }

    /// The preset on screen, when the sidebar is on one.
    private var shownPreset: FilterPreset? {
        if case let .filterPreset(id) = selection {
            return catalog.filterPresets.preset(id: id)
        }
        return nil
    }

    /// The library a preset saved from what is on screen filters: the library shown, or the one of
    /// the preset shown. Nil for the map of every library, which lists no photo.
    private var presetLibrary: FilterPreset.Library? {
        switch selection {
        case .photos: .photos
        case let .photosAlbum(id): .photosAlbum(id: id)
        case let .folder(id): .folder(id: id, path: nil)
        case let .subfolder(id, path): .folder(id: id, path: path)
        case let .filterPreset(id): catalog.filterPresets.preset(id: id)?.library
        case .map, nil: nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .map:
            MapLibraryView(source: catalog.everywhere, maps: maps)
        case .photos:
            PhotosLibraryView(source: catalog.photos, albums: catalog.photosAlbums, albumEditor: catalog.photosAlbumEditor, maps: maps)
        case let .photosAlbum(id):
            if let album = catalog.photosAlbums.album(id: id) {
                PhotosLibraryView(source: catalog.photosSource(for: album), albums: catalog.photosAlbums, albumEditor: catalog.photosAlbumEditor,
                                  maps: maps)
                    .id(album.id)
            } else {
                ContentUnavailableView("Album Removed", systemImage: "rectangle.stack.badge.minus")
            }
        case let .folder(id):
            folderView(id: id, path: nil)
        case let .subfolder(id, path):
            folderView(id: id, path: path)
        case let .filterPreset(id):
            if let preset = catalog.filterPresets.preset(id: id) {
                FilterPresetView(preset: preset, catalog: catalog, maps: maps)
                    .id(preset.id)
            } else {
                ContentUnavailableView("Filter Preset Removed", systemImage: "line.3.horizontal.decrease.circle")
            }
        case nil:
            ContentUnavailableView("Select a Library", systemImage: "sidebar.left",
                                   description: Text("Choose Photos or a folder in the sidebar."))
        }
    }

    @ViewBuilder
    private func folderView(id: FolderLibrarySource.ID, path: String?) -> some View {
        if let folder = catalog.folders.first(where: { $0.id == id }) {
            FolderLibraryView(source: folder, path: path, maps: maps)
                .id(folder.id)
        } else {
            ContentUnavailableView("Folder Removed", systemImage: "folder.badge.minus")
        }
    }

    private func addFolder(_ result: Result<URL, Error>) async {
        do {
            let folder = try await catalog.addFolder(result.get())
            selection = .folder(folder.id)
        } catch {
            folderError = error.localizedDescription
        }
    }
}
