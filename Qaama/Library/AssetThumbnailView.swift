import LibraryKit
import SwiftUI

/// Square thumbnail of a photo, loaded on demand.
struct AssetThumbnailView: View {
    let asset: LibraryAsset
    let source: any LibrarySource
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            HStack {
                if asset.rating > 0 {
                    Label("\(asset.rating)", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.bold())
                }
                Spacer()
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                }
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(6)
        }
        .task(id: asset.id) {
            let pixels = CGSize(width: side * displayScale, height: side * displayScale)
            image = await source.thumbnail(for: asset, pixelSize: pixels)
        }
    }
}
