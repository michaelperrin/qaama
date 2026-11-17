import LibraryKit
import SwiftUI

/// How a library's view was left for an album named in its Info panel: what puts it back as it was.
struct LibraryPlace {
    var selection: Set<LibraryAsset.ID> = []
    /// Where the grid was scrolled; nil when the map was shown.
    var grid: GridPlace?
    /// The photo open in the editor, if one was.
    var editedAssetID: LibraryAsset.ID?
}

/// The way back from a library reached through a link, for the toolbar's Back button and View › Back.
struct BackAction {
    /// What going back leads to, as a sentence for the button's help.
    let help: String
    let go: () -> Void
}

/// The place a library's view is to be put back in when Back leads to it. Handed over once, to the
/// view shown for the library it was noted for.
final class LibraryArrival {
    private var expected: (location: LibrarySelection, place: LibraryPlace)?

    func expect(_ place: LibraryPlace, at location: LibrarySelection) {
        expected = (location, place)
    }

    /// Forgets a place noted for another library than the one now shown.
    func moved(to location: LibrarySelection?) {
        if expected?.location != location {
            expected = nil
        }
    }

    func take() -> LibraryPlace? {
        defer { expected = nil }
        return expected?.place
    }
}

/// What the window gives the view of a library to leave it for an album and to come back.
struct LibraryVisits {
    /// The album hierarchy of the Photos library, as the sidebar shows it.
    let albums: PhotosAlbumList
    /// The album on screen; nil elsewhere.
    let currentAlbumID: PhotosAlbum.ID?
    let arrival: LibraryArrival
    /// Nil unless this library was reached through a link.
    let back: BackAction?
    /// Shows an album in place of this library, which is left as the place describes.
    let open: (PhotosAlbum.ID, LibraryPlace) -> Void
}

extension EnvironmentValues {
    /// Nil where there is no window to navigate (previews).
    @Entry var libraryVisits: LibraryVisits?
}

struct FocusedBackKey: FocusedValueKey {
    typealias Value = BackAction
}

extension FocusedValues {
    /// What View › Back does in the key window: close the editor, leave a group of the map, or go
    /// back from an album reached through a link. Nil when there is nothing to go back to.
    var backAction: BackAction? {
        get { self[FocusedBackKey.self] }
        set { self[FocusedBackKey.self] = newValue }
    }
}
