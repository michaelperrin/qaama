import CoreTransferable
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// Photos dragged inside Qaama, by identifier; declared in Info.plist.
    static let qaamaPhotos = UTType(exportedAs: "fr.michaelperrin.qaama.photos")
}

/// The photos being dragged from the grid to an album of the sidebar. Identifiers only: they mean
/// nothing outside Qaama, so no other app accepts the drag.
nonisolated struct PhotoDrag: Codable, Transferable {
    let assetIDs: [LibraryAsset.ID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .qaamaPhotos)
    }
}

/// Lets a thumbnail be dragged, where the library has somewhere to drop it. The photos are looked up
/// when the drag starts, not on every update of the grid.
struct PhotoDragSource: ViewModifier {
    let isEnabled: Bool
    let assetIDs: () -> [LibraryAsset.ID]

    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(PhotoDrag(assetIDs: assetIDs()))
        } else {
            content
        }
    }
}
