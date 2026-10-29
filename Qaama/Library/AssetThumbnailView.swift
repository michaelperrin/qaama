import EditModel
import LibraryKit
import RenderEngine
import SwiftUI

/// Square thumbnail of a photo, loaded on demand.
struct AssetThumbnailView: View {
    let asset: LibraryAsset
    let source: any LibrarySource
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    /// What the thumbnail depends on: a new edit changes the modification date, so the task reruns.
    private struct ThumbnailKey: Hashable {
        let id: LibraryAsset.ID
        let modificationDate: Date?
    }

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
                if asset.hasEdit {
                    Image(systemName: "slider.horizontal.3")
                        .help("Edited")
                }
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                }
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(6)
        }
        .task(id: ThumbnailKey(id: asset.id, modificationDate: asset.modificationDate)) {
            let pixels = CGSize(width: side * displayScale, height: side * displayScale)
            guard let thumbnail = await source.thumbnail(for: asset, pixelSize: pixels) else { return }
            if let data = await source.savedRecipeData(for: asset), let recipe = try? EditRecipe(jsonData: data) {
                image = await Task.detached { ThumbnailRenderer.apply(recipe, to: thumbnail) }.value ?? thumbnail
            } else {
                image = thumbnail
            }
        }
    }
}
