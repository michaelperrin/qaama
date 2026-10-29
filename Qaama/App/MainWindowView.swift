import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Which library the sidebar shows in the detail column.
enum LibrarySelection: Hashable {
    case photos
    case folder(FolderLibrarySource.ID)
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
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            addFolder(result)
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
            PhotosLibraryView(source: catalog.photos)
        case let .folder(id):
            if let folder = catalog.folders.first(where: { $0.id == id }) {
                FolderLibraryView(source: folder)
                    .id(folder.id)
            } else {
                ContentUnavailableView("Folder Removed", systemImage: "folder.badge.minus")
            }
        case nil:
            ContentUnavailableView("Select a Library", systemImage: "sidebar.left",
                                   description: Text("Choose Photos or a folder in the sidebar."))
        }
    }

    private func addFolder(_ result: Result<URL, Error>) {
        do {
            let folder = try catalog.addFolder(result.get())
            selection = .folder(folder.id)
        } catch {
            folderError = error.localizedDescription
        }
    }
}
