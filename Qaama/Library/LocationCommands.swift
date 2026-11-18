import LibraryKit
import SwiftUI

/// What the Location items of the Image menu and of the thumbnails' context menu do.
enum LocationCommand {
    /// Opens the Location section of the Info panel, ready to search for a place.
    case assign
    case remove
    case revert
}

/// Asks the Location section of the Info panel to start editing, from a menu: the photos it is for,
/// kept until the section showing those photos takes the request. The section may not exist yet
/// when it is asked (the inspector was hidden, the selection is changing).
@Observable
final class LocationEditRequest {
    private(set) var pending: Set<LibraryAsset.ID>?

    func ask(for ids: [LibraryAsset.ID]) {
        pending = Set(ids)
    }

    /// True, once, when the request is for these photos.
    func take(for ids: [LibraryAsset.ID]) -> Bool {
        guard let pending, pending == Set(ids) else { return false }
        self.pending = nil
        return true
    }
}

extension EnvironmentValues {
    /// The window's requests to edit a location; nil where no menu asks (previews).
    @Entry var locationEditRequest: LocationEditRequest?
}

/// What Image › Location acts on in the key window: the photo open in the editor, or the grid's
/// selection. Each item is nil when it can't act (the menu disables it).
struct LocationAction {
    var assign: (() -> Void)?
    var remove: (() -> Void)?
    /// Nil also where the library keeps no original location apart (Photos).
    var revert: (() -> Void)?
}

struct FocusedLocationKey: FocusedValueKey {
    typealias Value = LocationAction
}

extension FocusedValues {
    var locationAction: LocationAction? {
        get { self[FocusedLocationKey.self] }
        set { self[FocusedLocationKey.self] = newValue }
    }
}
