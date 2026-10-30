import LibraryKit
import SwiftUI

/// Square thumbnail of a photo, loaded on demand.
struct AssetThumbnailView: View {
    let asset: LibraryAsset
    let source: any LibrarySource
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var resources: AssetResourceInfo?

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
        .opacity(asset.flag == .rejected ? 0.45 : 1)
        .overlay(alignment: .bottom) {
            HStack {
                if asset.rating > 0 {
                    Label("\(asset.rating)", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.bold())
                }
                switch asset.flag {
                case .picked: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Picked")
                case .rejected: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Rejected")
                case .none: EmptyView()
                }
                Spacer()
                if let resources = resources ?? (asset.isRAW ? AssetResourceInfo(asset) : nil), resources.isRAW {
                    Text(resources.hasJPEGTwin ? "RAW+JPG" : "RAW")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.45), in: .capsule)
                        .help(resources.hasJPEGTwin ? "RAW with its JPEG twin" : "RAW file")
                }
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
            source.prioritize(asset)
            let pixels = CGSize(width: side * displayScale, height: side * displayScale)
            image = await source.thumbnail(for: asset, pixelSize: pixels)
            resources = await source.resourceInfo(for: asset)
        }
    }
}

#Preview("Decisions") {
    let source = SampleLibrarySource(count: 8)
    HStack {
        ForEach(source.assets.indices, id: \.self) { index in
            AssetThumbnailView(asset: source.assets[index], source: source, side: 120)
        }
    }
    .padding()
}
