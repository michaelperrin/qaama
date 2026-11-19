import LibraryKit
import SwiftUI

/// Thumbnail of a photo in a square of `side`, loaded on demand: the photo cropped to the square, or
/// whole inside it, as `fit` says. In the latter case the place is reserved at the photo's shape before
/// the pixels arrive (from `LibraryAsset.aspectRatio`), so nothing moves when they do; once loaded, the
/// pixels' own shape wins (an edit may have cropped the photo).
struct AssetThumbnailView: View {
    let asset: LibraryAsset
    let source: any LibrarySource
    let side: CGFloat
    var fit = ThumbnailFit.fill
    var isSelected = false

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    /// The photo `image` shows: a cell keeps its pixels while it waits for those of another photo.
    @State private var imageAssetID: LibraryAsset.ID?
    @State private var resources: AssetResourceInfo?

    /// How long a cell keeps the pixels of the photo its row held before, while it waits for those
    /// of the photo it holds now.
    private static let stalePixelsGrace = Duration.milliseconds(150)

    /// What the thumbnail depends on: a new edit changes the modification date, so the task reruns; so
    /// does a zoom past a pixel step, or a change of shape, which asks the source for other pixels.
    private struct ThumbnailKey: Hashable {
        let id: LibraryAsset.ID
        let modificationDate: Date?
        let pixels: CGFloat
        let fit: ThumbnailFit
    }

    var body: some View {
        let imageSize = fit.displaySize(inSquare: side, aspectRatio: image.map { Double($0.width) / Double($0.height) } ?? asset.aspectRatio)
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            if isSelected {
                SelectionRing(cornerRadius: 6)
            }
        }
        // Room for the selection ring, which is drawn around the photo.
        .padding(SelectionRing.width)
        // A photo still on a card that was imported already steps back like a rejected one.
        .opacity(asset.flag == .rejected || asset.isImported ? 0.45 : 1)
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
                if asset.isImported {
                    Image(systemName: "checkmark.circle.fill")
                        .help("Already imported")
                }
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                }
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(6)
        }
        // The square the grid lays out, whatever shape the photo takes inside it.
        .frame(width: side + 4, height: side + 4)
        // Switching between square and whole: the photo's frame grows or shrinks to its new shape.
        .animation(.snappy(duration: 0.3), value: fit)
        .task(id: ThumbnailKey(id: asset.id, modificationDate: asset.modificationDate, pixels: requestPixels.width, fit: fit)) {
            source.prioritize(asset)
            // The cell shows another photo: the listing changed under it. Its pixels may stay a
            // moment, so that a fast source goes from one photo to the other without a blink, but
            // not for long: while a slow source reads the right photo (a card: up to seconds), the
            // cell would show the wrong one.
            let clearing = imageAssetID != nil && imageAssetID != asset.id ? Task {
                try? await Task.sleep(for: Self.stalePixelsGrace)
                if !Task.isCancelled, imageAssetID != asset.id {
                    image = nil
                    imageAssetID = nil
                }
            } : nil
            defer { clearing?.cancel() }
            // Where the real thumbnail takes long (a card), a coarse one first, unless this photo
            // already shows: a zoom must not go back to it.
            if imageAssetID != asset.id, let quick = await source.quickThumbnail(for: asset), !Task.isCancelled {
                image = quick
                imageAssetID = asset.id
            }
            // The previous pixels stay on screen until the new ones are in hand, or the request is superseded.
            let loaded = await source.thumbnail(for: asset, pixelSize: requestPixels, fit: fit)
            guard !Task.isCancelled else { return }
            if let loaded {
                image = loaded
                imageAssetID = asset.id
            }
            resources = await source.resourceInfo(for: asset)
        }
    }

    private var requestPixels: CGSize {
        GridDisplay.requestPixels(forSide: side, displayScale: displayScale)
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

#Preview("Whole photos") {
    let source = SampleLibrarySource(count: 6)
    HStack {
        ForEach(source.assets.indices, id: \.self) { index in
            AssetThumbnailView(asset: source.assets[index], source: source, side: 120, fit: .fit, isSelected: index == 1)
        }
    }
    .padding()
}
