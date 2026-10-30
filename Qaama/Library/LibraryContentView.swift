import LibraryKit
import SwiftUI

/// Detail column of a library: the thumbnail grid, replaced by the editor while a photo is open.
struct LibraryContentView: View {
    let source: any LibrarySource
    @State private var editedAssetID: LibraryAsset.ID?

    var body: some View {
        if let editedAssetID {
            EditorView(assetID: editedAssetID, source: source) { self.editedAssetID = nil }
                .id(editedAssetID)
                .navigationTitle(source.displayName)
                .navigationSubtitle("Editing")
        } else {
            AssetGridView(source: source) { editedAssetID = $0 }
                .navigationTitle(source.displayName)
                .navigationSubtitle(subtitle)
        }
    }

    private var subtitle: String {
        guard !source.assets.isEmpty else { return "" }
        var text = "\(source.assets.count) photos"
        if let duration = source.lastLoadDuration {
            text += " · listed in \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))"
        }
        return text
    }
}

#Preview("Grid then editor") {
    LibraryContentView(source: SampleLibrarySource())
        .frame(width: 900, height: 600)
}
