import LibraryKit
import SwiftUI

/// Lists the Apple Photos library and the folders the user added.
struct SidebarView: View {
    let catalog: LibraryCatalog
    @Binding var selection: LibrarySelection?
    let addFolder: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Apple Photos") {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
                    .tag(LibrarySelection.photos)
            }
            Section("Folders") {
                ForEach(catalog.folders) { folder in
                    Label(folder.displayName, systemImage: "folder")
                        .tag(LibrarySelection.folder(folder.id))
                        .help(folder.folderURL.path(percentEncoded: false))
                        .contextMenu {
                            Button("Rescan Folder") { folder.invalidate(); Task { await folder.load() } }
                            Button("Remove Folder", role: .destructive) { remove(folder) }
                        }
                }
                if catalog.folders.isEmpty {
                    Text("No folders yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button(action: addFolder) {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .help("Add a folder of photos")
            }
        }
    }

    private func remove(_ folder: FolderLibrarySource) {
        if selection == .folder(folder.id) {
            selection = .photos
        }
        catalog.removeFolder(folder)
    }
}
