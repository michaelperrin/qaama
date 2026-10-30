import LibraryKit
import SwiftUI

/// Lists the Apple Photos library with its albums, and the folders the user added with their subfolders.
struct SidebarView: View {
    let catalog: LibraryCatalog
    @Binding var selection: LibrarySelection?
    let addFolder: () -> Void
    @State private var albumsExpanded = false

    var body: some View {
        List(selection: $selection) {
            Section("Apple Photos") {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
                    .tag(LibrarySelection.photos)
                ForEach(catalog.photosAlbums.albums.filter { $0.kind == .favorites }) { album in
                    albumRow(album, symbol: "heart")
                }
                let userAlbums = catalog.photosAlbums.albums.filter { $0.kind == .user }
                if !userAlbums.isEmpty {
                    // Libraries can hold hundreds of albums: keep them folded until asked for.
                    DisclosureGroup(isExpanded: $albumsExpanded) {
                        ForEach(userAlbums) { album in
                            albumRow(album, symbol: "rectangle.stack")
                        }
                    } label: {
                        Label("Albums", systemImage: "rectangle.stack.badge.person.crop")
                            .badge(userAlbums.count)
                    }
                }
            }
            Section("Folders") {
                ForEach(catalog.folders) { folder in
                    folderRow(folder)
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

    private func albumRow(_ album: PhotosAlbum, symbol: String) -> some View {
        Label(album.title, systemImage: symbol)
            .tag(LibrarySelection.photosAlbum(album.id))
            .badge(album.estimatedCount > 0 ? album.estimatedCount : 0)
    }

    @ViewBuilder
    private func folderRow(_ folder: FolderLibrarySource) -> some View {
        let label = Label(folder.displayName, systemImage: "folder")
            .help(folder.folderURL.path(percentEncoded: false))
            .contextMenu {
                Button("Rescan Folder") { folder.rescan() }
                Button("Remove Folder", role: .destructive) { remove(folder) }
            }
        if folder.subfolders.isEmpty {
            label.tag(LibrarySelection.folder(folder.id))
        } else {
            DisclosureGroup {
                OutlineGroup(folder.subfolders, children: \.optionalChildren) { node in
                    Label(node.name, systemImage: "folder")
                        .tag(LibrarySelection.subfolder(folder.id, node.path))
                }
            } label: {
                label.tag(LibrarySelection.folder(folder.id))
            }
        }
    }

    private func remove(_ folder: FolderLibrarySource) {
        switch selection {
        case .folder(folder.id), .subfolder(folder.id, _): selection = .photos
        default: break
        }
        Task { try? await catalog.removeFolder(folder) }
    }
}

private extension FolderNode {
    /// `OutlineGroup` wants nil for leaves, not an empty array.
    var optionalChildren: [FolderNode]? {
        children.isEmpty ? nil : children
    }
}

#Preview {
    @Previewable @State var selection: LibrarySelection? = .photos
    SidebarView(catalog: LibraryCatalog(store: try! CatalogStore.inMemory()), selection: $selection) {}
        .frame(width: 220, height: 400)
}
