import LibraryKit
import SwiftUI

/// Lists the Apple Photos library with its album hierarchy, and the folders the user added with their
/// subdirectories. Both sections are outlines over `SidebarItem`, so every row selects the same way.
struct SidebarView: View {
    let catalog: LibraryCatalog
    @Binding var selection: LibrarySelection?
    let addFolder: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Apple Photos") {
                OutlineGroup(photosItems, children: \.children) { item in
                    row(item)
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
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        let label = Label(item.title, systemImage: item.symbol)
            .badge(item.badge ?? 0)
            .help(item.help ?? "")
        if let selection = item.selection {
            label.tag(selection)
        } else {
            label.selectionDisabled()
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
        if !albums.tree.isEmpty {
            // Libraries can hold hundreds of albums: one collapsed root keeps the sidebar short.
            items.append(SidebarItem(id: "albums", title: "Albums", symbol: "rectangle.stack.badge.person.crop", selection: nil,
                                     badge: albums.albums.filter { $0.kind == .user }.count,
                                     children: albums.tree.map(SidebarItem.init)))
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
    let id: String
    let title: String
    let symbol: String
    /// Nil for rows that only group others (album folders, the Albums root).
    let selection: LibrarySelection?
    var badge: Int?
    var help: String?
    var folder: FolderLibrarySource?
    var children: [SidebarItem]?

    init(id: String, title: String, symbol: String, selection: LibrarySelection?, badge: Int? = nil, help: String? = nil,
         folder: FolderLibrarySource? = nil, children: [SidebarItem]? = nil)
    {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.selection = selection
        self.badge = badge.flatMap { $0 > 0 && $0 != NSNotFound ? $0 : nil }
        self.help = help
        self.folder = folder
        self.children = children
    }

    init(_ node: PhotosAlbumNode) {
        switch node {
        case let .album(album):
            self.init(id: album.id, title: album.title, symbol: "rectangle.stack", selection: .photosAlbum(album.id), badge: album.estimatedCount)
        case let .folder(id, title, children):
            self.init(id: id, title: title, symbol: "folder", selection: nil, children: children.map(SidebarItem.init))
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
