import LibraryKit
import SwiftUI

/// Thumbnail grid shared by every library source, with a sheet showing the tapped photo.
struct AssetGridView: View {
    let source: any LibrarySource
    @State private var selection: Selection?

    /// Identifiable wrapper so a sheet can be driven by the asset identifier alone.
    private struct Selection: Identifiable {
        let id: LibraryAsset.ID
    }

    private let thumbnailSide: CGFloat = 160

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 8)], spacing: 8) {
                ForEach(source.assets) { asset in
                    AssetThumbnailView(asset: asset, source: source, side: thumbnailSide)
                        .onTapGesture { selection = Selection(id: asset.id) }
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
        .sheet(item: $selection) { selection in
            AssetDetailView(assetID: selection.id, source: source)
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
