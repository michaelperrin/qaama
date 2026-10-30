import LibraryKit
import SwiftUI

/// Thumbnail grid shared by every library source. Tapping a photo reports its identifier.
struct AssetGridView: View {
    let source: any LibrarySource
    let onOpen: (LibraryAsset.ID) -> Void

    private let thumbnailSide: CGFloat = 160

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 8)], spacing: 8) {
                // Iterate indices, not elements: ForEach over elements walks the whole collection to compute
                // identities, which is far too slow for a lazily computed library of tens of thousands of rows.
                ForEach(source.assets.indices, id: \.self) { index in
                    let asset = source.assets[index]
                    AssetThumbnailView(asset: asset, source: source, side: thumbnailSide)
                        .onTapGesture { onOpen(asset.id) }
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
    }
}

#Preview("Sample library") {
    AssetGridView(source: SampleLibrarySource()) { _ in }
        .frame(width: 720, height: 500)
}

#Preview("Empty") {
    AssetGridView(source: SampleLibrarySource(count: 0)) { _ in }
        .frame(width: 400, height: 300)
}
