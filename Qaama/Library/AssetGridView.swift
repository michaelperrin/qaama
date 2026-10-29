import LibraryKit
import SwiftUI

/// Thumbnail grid shared by every library source; tapping a photo opens the editor in its place.
struct AssetGridView: View {
    let source: any LibrarySource
    @State private var editedAssetID: LibraryAsset.ID?

    private let thumbnailSide: CGFloat = 160

    var body: some View {
        if let editedAssetID {
            EditorView(assetID: editedAssetID, source: source) { self.editedAssetID = nil }
                .id(editedAssetID)
                .navigationTitle(source.displayName)
                .navigationSubtitle("Editing")
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 8)], spacing: 8) {
                ForEach(source.assets) { asset in
                    AssetThumbnailView(asset: asset, source: source, side: thumbnailSide)
                        .onTapGesture { editedAssetID = asset.id }
                }
            }
            .padding(12)
        }
        .overlay {
            if source.assets.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("This library doesn't contain any images."))
            }
        }
        .navigationTitle(source.displayName)
        .navigationSubtitle(subtitle)
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
