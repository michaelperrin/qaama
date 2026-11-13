import Foundation
import Observation

/// Choosing an album by typing part of its name: what was typed, the albums it finds and the one
/// Return would choose, which the arrow keys move. The view only draws it.
///
/// The albums are those of the hierarchy handed in: a search is short-lived, and doesn't follow the
/// changes made to the library while it is open.
@Observable
public final class PhotosAlbumPickerModel {
    public var query = "" {
        didSet {
            if query != oldValue {
                refresh()
            }
        }
    }

    /// The albums found, best first; every album while nothing is typed.
    public private(set) var matches: [PhotosAlbumSearch.Match]
    /// The album Return chooses: the best match, until the arrow keys move it. Nil when nothing is found.
    public private(set) var highlightedID: PhotosAlbum.ID?
    /// How many albums there are to search in.
    public let albumCount: Int

    private let search: PhotosAlbumSearch

    /// `excludedID` leaves one album out: the one on screen, which adding to makes no sense.
    public init(tree: [PhotosAlbumNode], excluding excludedID: PhotosAlbum.ID? = nil) {
        search = PhotosAlbumSearch(tree: tree, excluding: excludedID)
        albumCount = search.count
        matches = search.matches(for: "")
        highlightedID = matches.first?.id
    }

    public var highlighted: PhotosAlbum? {
        matches.first { $0.id == highlightedID }?.album
    }

    /// Moves the highlight down (positive) or up the results, stopping at both ends.
    public func moveHighlight(by offset: Int) {
        guard !matches.isEmpty else { return }
        guard let index = matches.firstIndex(where: { $0.id == highlightedID }) else {
            highlightedID = matches.first?.id
            return
        }
        highlightedID = matches[min(max(index + offset, 0), matches.count - 1)].id
    }

    private func refresh() {
        matches = search.matches(for: query)
        highlightedID = matches.first?.id
    }
}
