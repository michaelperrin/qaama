import ImageIOKit
import LibraryKit
import SwiftUI

/// A group of photos on the map: the thumbnail of its most recent photo and, for more than one, how
/// many they are. The thumbnail is handed in already loaded (see `PhotoMapModel.cover(of:)`): a
/// marker that loaded its own would show empty first, every time zooming replaces the groups.
/// Equatable and free of closures, so moving the map doesn't run the body of every marker again;
/// the gestures are attached by the map.
struct PhotoClusterMarker: View, Equatable {
    let coverID: LibraryAsset.ID
    let count: Int
    let isSelected: Bool
    /// Images count by identity: a reloaded thumbnail is another object.
    let image: CGImage?

    /// Side of the thumbnail, in points.
    static let side: CGFloat = 64
    /// The least distance between two markers the map asks its model for: a thumbnail and some air.
    static let spacing: Double = 88
    private static let cornerRadius: CGFloat = 8

    @Environment(\.displayScale) private var displayScale

    init(cluster: PhotoCluster, image: CGImage?, isSelected: Bool) {
        coverID = cluster.coverID
        count = cluster.count
        self.image = image
        self.isSelected = isSelected
    }

    nonisolated static func == (lhs: PhotoClusterMarker, rhs: PhotoClusterMarker) -> Bool {
        lhs.coverID == rhs.coverID && lhs.count == rhs.count && lhs.isSelected == rhs.isSelected && lhs.image === rhs.image
    }

    var body: some View {
        ZStack {
            // Opaque: the map must not show through while the photo loads.
            Rectangle().fill(.background)
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(alignment: .bottomLeading) {
            if count > 1 {
                Text(count.formatted())
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Keeps the number readable on a bright photo.
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
            }
        }
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(isSelected ? Color.accentColor : .white, lineWidth: isSelected ? 3 : 2)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
        .help(count == 1 ? "1 photo" : "\(count.formatted()) photos")
        .accessibilityElement()
        .accessibilityLabel(count == 1 ? "1 photo" : "\(count.formatted()) photos")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Pixels of a marker's thumbnail on a screen of this scale, on the grid's pixel steps: one the
    /// grid already asked for at this size is in PhotoKit's cache.
    static func requestPixels(displayScale: CGFloat) -> CGSize {
        GridDisplay.requestPixels(forSide: side, displayScale: displayScale)
    }
}

#Preview {
    let cluster = PhotoMapIndex([LocatedAsset(id: "sample-0", coordinate: .init(latitude: 48.86, longitude: 2.35)),
                                 LocatedAsset(id: "sample-1", coordinate: .init(latitude: 48.86, longitude: 2.35))]).clusters(level: 0)[0]
    HStack(spacing: 20) {
        PhotoClusterMarker(cluster: cluster, image: nil, isSelected: false)
        PhotoClusterMarker(cluster: cluster, image: nil, isSelected: true)
    }
    .padding(30)
    .background(.green.opacity(0.3))
}
