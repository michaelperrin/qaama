import LibraryKit
import SwiftUI

/// Lists the Apple Photos library with its album hierarchy, and the folders the user added with their
/// subdirectories. Both sections are outlines over `SidebarItem`, so every row selects the same way.
///
/// Albums are managed from here: the context menus create albums and folders and delete albums, and
/// photos dragged from the grid onto an album are added to it.
struct SidebarView: View {
    let catalog: LibraryCatalog
    @Binding var selection: LibrarySelection?
    let addFolder: () -> Void

    /// The album question being asked: a name for a new album or folder, or a deletion to confirm.
    @State private var albumDialog: AlbumDialog?
    @State private var albumError: String?
    /// The album row photos are being dragged over.
    @State private var dropTargetID: String?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: $selection) {
            Section("Apple Photos") {
                OutlineGroup(photosItems, children: \.children) { item in
                    row(item)
                        .contextMenu { albumMenu(for: item) }
                }
            }
            Section("Folders") {
                OutlineGroup(folderItems, children: \.children) { item in
                    row(item)
                        .contextMenu {
                            if let folder = item.folder {
                                Button("Rescan Folder") { folder.rescan() }
                                Button("Remove Folder", role: .destructive) { remove(folder) }
                            }
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
        // File › New Album… and New Album Folder…, at the top level; nil until the albums are listed.
        .focusedSceneValue(\.newAlbumAction, catalog.photosAlbums.isLoaded ? NewAlbumAction(
            newAlbum: { albumDialog = .newAlbum(folderID: nil, assetIDs: []) },
            newFolder: { albumDialog = .newFolder(parentID: nil) }
        ) : nil)
        .albumDialogs($albumDialog, editor: catalog.photosAlbumEditor, error: $albumError, onCreated: { asked, id in
            // The new album opens, empty, as in Photos; a folder has nothing to show.
            if case .newAlbum = asked {
                selection = .photosAlbum(id)
            }
        }, onDeleted: { album in
            if selection == .photosAlbum(album.id) {
                selection = .photos
            }
        })
        .alert("Couldn't Update the Albums", isPresented: Binding(get: { albumError != nil }, set: {
            if !$0 {
                albumError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(albumError ?? "")
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        let label = label(item)
            .badge(item.badge ?? 0)
            .help(item.help ?? "")
        if let selection = item.selection {
            label.tag(selection)
        } else {
            label.selectionDisabled()
        }
    }

    /// The row's label; an album's also takes the photos dragged from the grid, over the whole row.
    @ViewBuilder
    private func label(_ item: SidebarItem) -> some View {
        if case let .album(album) = item.role {
            Label(item.title, systemImage: item.symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .background(dropTargetID == item.id ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                .dropDestination(for: PhotoDrag.self) { drags, _ in
                    add(drags.flatMap(\.assetIDs), to: album)
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted {
                        dropTargetID = item.id
                    } else if dropTargetID == item.id {
                        dropTargetID = nil
                    }
                }
        } else {
            Label(item.title, systemImage: item.symbol)
        }
    }

    /// Albums and folders are created where the click was: in the folder, or at the top level from
    /// the Albums row.
    @ViewBuilder
    private func albumMenu(for item: SidebarItem) -> some View {
        switch item.role {
        case .albumsRoot:
            Button("New Album…") { albumDialog = .newAlbum(folderID: nil, assetIDs: []) }
            Button("New Folder…") { albumDialog = .newFolder(parentID: nil) }
        case let .albumFolder(id):
            Button("New Album…") { albumDialog = .newAlbum(folderID: id, assetIDs: []) }
            Button("New Folder…") { albumDialog = .newFolder(parentID: id) }
        case let .album(album):
            Button("Delete Album…", role: .destructive) { albumDialog = .delete(album) }
        case .plain:
            EmptyView()
        }
    }

    private func add(_ assetIDs: [LibraryAsset.ID], to album: PhotosAlbum) {
        guard !assetIDs.isEmpty else { return }
        Task {
            do {
                try await catalog.photosAlbumEditor.add(assetIDs, toAlbum: album.id, undoManager: undoManager)
            } catch {
                albumError = error.localizedDescription
            }
        }
    }

    // MARK: - Items

    private var photosItems: [SidebarItem] {
        let albums = catalog.photosAlbums
        var items = [SidebarItem(id: "photos", title: "Photos", symbol: "photo.on.rectangle.angled", selection: .photos)]
        if let favorites = albums.favorites {
            items.append(SidebarItem(id: favorites.id, title: favorites.title, symbol: "heart",
                                     selection: .photosAlbum(favorites.id), badge: favorites.estimatedCount))
        }
        if albums.isLoaded {
            // Libraries can hold hundreds of albums: one collapsed root keeps the sidebar short. It is
            // there even without albums: its context menu creates the first one.
            items.append(SidebarItem(id: "albums", title: "Albums", symbol: "rectangle.stack.badge.person.crop", selection: nil,
                                     badge: albums.albums.filter { $0.kind == .user }.count, role: .albumsRoot,
                                     children: albums.tree.isEmpty ? nil : albums.tree.map(SidebarItem.init)))
        }
        return items
    }

    private var folderItems: [SidebarItem] {
        catalog.folders.map { folder in
            SidebarItem(id: folder.id.uuidString, title: folder.displayName, symbol: "folder", selection: .folder(folder.id),
                        help: folder.folderURL.path(percentEncoded: false), folder: folder,
                        children: folder.subfolders.isEmpty ? nil : folder.subfolders.map { SidebarItem(folderID: folder.id, node: $0) })
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

/// One row of the sidebar outline.
private struct SidebarItem: Identifiable {
    /// What the row stands for in the album hierarchy, which decides its context menu and whether
    /// photos can be dropped on it.
    enum Role {
        case plain
        /// The row holding every album and folder.
        case albumsRoot
        case albumFolder(id: String)
        /// An album of the user's, as opposed to Favorites.
        case album(PhotosAlbum)
    }

    let id: String
    let title: String
    let symbol: String
    /// Nil for rows that only group others (album folders, the Albums root).
    let selection: LibrarySelection?
    var badge: Int?
    var help: String?
    var folder: FolderLibrarySource?
    var role = Role.plain
    var children: [SidebarItem]?

    init(id: String, title: String, symbol: String, selection: LibrarySelection?, badge: Int? = nil, help: String? = nil,
         folder: FolderLibrarySource? = nil, role: Role = .plain, children: [SidebarItem]? = nil)
    {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.selection = selection
        self.badge = badge.flatMap { $0 > 0 && $0 != NSNotFound ? $0 : nil }
        self.help = help
        self.folder = folder
        self.role = role
        self.children = children
    }

    init(_ node: PhotosAlbumNode) {
        switch node {
        case let .album(album):
            self.init(id: album.id, title: album.title, symbol: "rectangle.stack", selection: .photosAlbum(album.id),
                      badge: album.estimatedCount, role: .album(album))
        case let .folder(id, title, children):
            // An empty folder is still an outline, so it reads as a folder albums can go into.
            self.init(id: id, title: title, symbol: "folder", selection: nil, role: .albumFolder(id: id), children: children.map(SidebarItem.init))
        }
    }

    init(folderID: FolderLibrarySource.ID, node: FolderNode) {
        self.init(id: "\(folderID)/\(node.path)", title: node.name, symbol: "folder", selection: .subfolder(folderID, node.path),
                  children: node.children.isEmpty ? nil : node.children.map { SidebarItem(folderID: folderID, node: $0) })
    }
}

#Preview {
    @Previewable @State var selection: LibrarySelection? = .photos
    SidebarView(catalog: LibraryCatalog(store: try! CatalogStore.inMemory()), selection: $selection) {}
        .frame(width: 220, height: 400)
}
