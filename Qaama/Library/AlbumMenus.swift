import LibraryKit
import SwiftUI

/// Filing photos in the albums of the Photos library: what the grid's context menu and the Image menu
/// both offer. Only Photos libraries have it.
struct AlbumsAction {
    /// The album hierarchy to choose from.
    let list: PhotosAlbumList
    /// The album on screen, which adding to makes no sense; nil in the whole library.
    let currentAlbumID: PhotosAlbum.ID?
    /// The album photos were last added to, offered as a shortcut; nil when there is none yet, or
    /// when it is the one on screen.
    let lastAlbum: PhotosAlbum?
    let add: (PhotosAlbum, [LibraryAsset.ID]) -> Void
    /// Asks for a name, then creates an album holding these photos.
    let create: ([LibraryAsset.ID]) -> Void
    /// Removes photos from the album on screen; nil where there is none to remove them from.
    var remove: (([LibraryAsset.ID]) -> Void)?
}

/// The album items of a menu: Add to Album with the album hierarchy, Add to the last album, Remove
/// from Album. The photos they act on are looked up when an item is chosen.
///
/// A view of its own on purpose: SwiftUI runs a context menu's closure for every tile on every update
/// of the grid, but evaluates the body of a view inside it only when the menu opens (measured with
/// a probe). A library can hold hundreds of albums; listing them must cost nothing until then.
struct AlbumMenuItems: View {
    enum Placement {
        /// The Image menu: every item is always there, disabled when it doesn't apply, and holds the shortcut.
        case menuBar
        /// A context menu on `count` photos: only what applies is listed.
        case contextMenu(count: Int)
    }

    /// Nil when there is nothing to act on.
    let albums: AlbumsAction?
    let placement: Placement
    let targets: () -> [LibraryAsset.ID]

    @State private var pickTarget = AlbumPickTarget()

    var body: some View {
        // Not a state change: the tree only reads it when an album is chosen.
        let _ = pickTarget.pick = { album in albums?.add(album, targets()) }
        Menu("Add to Album") {
            if let albums {
                Button("New Album…") { albums.create(targets()) }
                Divider()
                AlbumTreeItems(nodes: albums.list.tree, disabledAlbumID: albums.currentAlbumID, target: pickTarget)
                    .equatable()
            }
        }
        .disabled(albums == nil)
        if let albums, let last = albums.lastAlbum {
            Button("Add to “\(last.title)”") { albums.add(last, targets()) }
                .keyboardShortcut(isMenuBar ? Self.addToLastShortcut : nil)
        } else if isMenuBar {
            Button("Add to Last Album") {}
                .keyboardShortcut(Self.addToLastShortcut)
                .disabled(true)
        }
        if let remove = albums?.remove {
            Button(removeTitle) { remove(targets()) }
        } else if isMenuBar {
            Button("Remove from Album") {}
                .disabled(true)
        }
    }

    /// ⌃⌘A, as in Photos. Held by the menu bar item only: a second holder would fire too.
    private static let addToLastShortcut = KeyboardShortcut("a", modifiers: [.control, .command])

    private var isMenuBar: Bool {
        if case .menuBar = placement {
            return true
        }
        return false
    }

    private var removeTitle: String {
        if case let .contextMenu(count) = placement, count > 1 {
            return "Remove \(count) Photos from Album"
        }
        return "Remove from Album"
    }
}

/// Receives the album chosen in the tree. A reference, the same from one update to the next, where a
/// closure would be a new one each time and make the whole tree look changed.
private final class AlbumPickTarget {
    var pick: (PhotosAlbum) -> Void = { _ in }
}

/// The album hierarchy as menu items: an item per album, a submenu per folder.
///
/// Equatable so that it is only built again when the albums change: the Image menu is updated on
/// every change of the selection, and a library can hold hundreds of albums. Not measured: the
/// tree is simply kept out of that path.
private struct AlbumTreeItems: View, Equatable {
    let nodes: [PhotosAlbumNode]
    let disabledAlbumID: PhotosAlbum.ID?
    let target: AlbumPickTarget

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case let .album(album):
                Button(album.title) { target.pick(album) }
                    .disabled(album.id == disabledAlbumID)
            case let .folder(_, title, children):
                Menu(title) {
                    AlbumTreeItems(nodes: children, disabledAlbumID: disabledAlbumID, target: target)
                }
            }
        }
    }

    nonisolated static func == (lhs: AlbumTreeItems, rhs: AlbumTreeItems) -> Bool {
        lhs.nodes == rhs.nodes && lhs.disabledAlbumID == rhs.disabledAlbumID && lhs.target === rhs.target
    }
}
