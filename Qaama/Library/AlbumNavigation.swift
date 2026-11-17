import LibraryKit
import SwiftUI

/// What the Info panels are given to name the albums a photo is in and to go to one. Set by the
/// view of the library, which knows what is left behind (see `LibraryVisits`).
struct AlbumNavigation {
    /// The album hierarchy of the Photos library, as the sidebar shows it.
    let list: PhotosAlbumList
    /// The album on screen, which there is no going to; nil elsewhere.
    var currentID: PhotosAlbum.ID?
    /// Shows an album in place of what the window shows.
    var open: (PhotosAlbum.ID) -> Void
}

extension EnvironmentValues {
    /// Nil where there is no window to navigate (previews): the panels then leave the albums out.
    @Entry var albumNavigation: AlbumNavigation?
}
