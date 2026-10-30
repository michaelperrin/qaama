import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Which library the sidebar shows in the detail column.
enum LibrarySelection: Hashable {
    case photos
    case photosAlbum(PhotosAlbum.ID)
    case folder(FolderLibrarySource.ID)
    /// A subdirectory of a folder, by relative path.
    case subfolder(FolderLibrarySource.ID, String)
}

/// Sidebar of libraries on the left, the selected library's grid on the right.
struct MainWindowView: View {
    let catalog: LibraryCatalog
    @State private var selection: LibrarySelection? = .photos
    @State private var isPickingFolder = false
    @State private var folderError: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(catalog: catalog, selection: $selection, addFolder: { isPickingFolder = true })
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
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

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .photos:
            PhotosLibraryView(source: catalog.photos, albums: catalog.photosAlbums)
        case let .photosAlbum(id):
            if let album = catalog.photosAlbums.albums.first(where: { $0.id == id }) {
                PhotosLibraryView(source: catalog.photosSource(for: album))
                    .id(album.id)
            } else {
                ContentUnavailableView("Album Removed", systemImage: "rectangle.stack.badge.minus")
            }
        case let .folder(id):
            folderView(id: id, path: nil)
        case let .subfolder(id, path):
            folderView(id: id, path: path)
        case nil:
            ContentUnavailableView("Select a Library", systemImage: "sidebar.left",
                                   description: Text("Choose Photos or a folder in the sidebar."))
        }
    }

    @ViewBuilder
    private func folderView(id: FolderLibrarySource.ID, path: String?) -> some View {
        if let folder = catalog.folders.first(where: { $0.id == id }) {
            FolderLibraryView(source: folder, path: path)
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
