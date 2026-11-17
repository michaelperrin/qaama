import LibraryKit
import SwiftUI

/// Duplicating and deleting photos: what Image › Duplicate and Image › Delete act on in the key
/// window (the photo open in the editor, or the grid's selection), and what the context menu of the
/// open photo offers. The photos are looked up when an item is chosen.
struct PhotoFilingAction {
    /// How many photos the items act on, for their titles.
    let count: Int
    /// Nil where the library can't copy a photo.
    let duplicate: (() -> Void)?
    /// Asks for confirmation first. Nil where the library can't delete a photo.
    let delete: (() -> Void)?

    static func duplicateTitle(count: Int) -> String {
        count > 1 ? "Duplicate \(count) Photos" : "Duplicate Photo"
    }

    static func deleteTitle(count: Int) -> String {
        count > 1 ? "Delete \(count) Photos" : "Delete Photo"
    }
}

/// Photos about to be deleted, waiting for the user's confirmation, with what the library says
/// deleting them does (`LibrarySource.deletionNotice(for:)`).
struct DeletionRequest {
    let assets: [LibraryAsset]
    let notice: String

    var title: String {
        assets.count == 1 ? "Delete this photo?" : "Delete \(assets.count.formatted()) photos?"
    }
}

extension View {
    /// Asks to confirm the deletion set in `request`, then calls `onConfirm` with its photos.
    ///
    /// The user chose Delete themselves, so the button isn't styled as destructive and Return
    /// confirms, as the guidelines ask for an action deliberately chosen. Libraries where the
    /// system asks by itself (Photos) never get here.
    func deletionConfirmation(_ request: Binding<DeletionRequest?>, onConfirm: @escaping ([LibraryAsset]) -> Void) -> some View {
        alert(request.wrappedValue?.title ?? "", isPresented: Binding(get: { request.wrappedValue != nil }, set: {
            if !$0 {
                request.wrappedValue = nil
            }
        }), presenting: request.wrappedValue) { asked in
            Button("Delete") { onConfirm(asked.assets) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { asked in
            Text(asked.notice)
        }
    }
}
