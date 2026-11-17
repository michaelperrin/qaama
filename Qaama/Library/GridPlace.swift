import LibraryKit
import SwiftUI

/// Where a grid is scrolled, told by a photo and where it shows: what the grid that later takes its
/// place needs to open on the same photos.
struct GridPlace: Equatable {
    /// The photo, and the row it had: the row is where it most likely still is, the identifier
    /// finds it when the listing changed in between.
    var assetID: LibraryAsset.ID
    var row: Int
    /// How far the top of its thumbnail is under the top of the grid's visible area; nil to show
    /// the photo in the middle of it.
    var top: CGFloat?
}

/// Keeps where a grid was for the grid that takes its place. A grid doesn't outlive what replaces
/// it (the editor, another library), and one made anew starts at the top: measured with a probe,
/// a scroll view put back on screen is at offset 0.
///
/// The grid on screen tells how to read its place (`read`) and takes `pending` once it can scroll.
@Observable
final class GridPlaceKeeper {
    /// Where the grid on screen is scrolled now; nil when it shows no photo.
    @ObservationIgnored var read: () -> GridPlace? = { nil }
    /// Where the next grid opens, or the one on screen goes; the grid empties it when it has.
    var pending: GridPlace?
    /// Where the grid was when the editor took its place. Kept apart from `pending`, which the grid
    /// still on screen would take at once.
    @ObservationIgnored private(set) var left: GridPlace?
    @ObservationIgnored private var openedID: LibraryAsset.ID?

    /// The editor opens on a photo, in place of a grid that was at `place`.
    func open(_ id: LibraryAsset.ID, leavingGridAt place: GridPlace?) {
        left = place
        openedID = id
    }

    /// The editor closes on a photo, at `row` of the listing: the grid comes back where it was, or
    /// around that photo when the editor stepped to another one than it was opened on.
    func close(on id: LibraryAsset.ID, row: Int?) {
        if id != openedID, let row {
            pending = GridPlace(assetID: id, row: row, top: nil)
        } else {
            pending = left
        }
        left = nil
        openedID = nil
    }
}
