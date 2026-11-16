import SwiftUI

/// The mark of a selected photo, wherever one is shown: in the grid, on the map, in the export list.
/// A thin ring in the text color (near black, or near white in Dark Mode) around the photo, set off
/// from it by a band of the background color: the photo seems to step back inside the ring, and the
/// ring shows whatever the photo is.
///
/// Laid over the photo, at its corner radius. The band covers the photo's edge rather than shrinking
/// it, and the ring is drawn just outside its bounds: nothing moves when the selection changes, but
/// the photo needs `width` points of room around it.
///
/// Not the accent color: the app's is a neutral gray, which a photo swallows.
struct SelectionRing: View {
    var cornerRadius: CGFloat

    /// Thickness of the ring, outside the photo's bounds.
    static let width: CGFloat = 2
    /// Thickness of the band between the ring and the photo.
    private static let gap: CGFloat = 3

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.background, lineWidth: Self.gap)
            RoundedRectangle(cornerRadius: cornerRadius + Self.width)
                .strokeBorder(.primary, lineWidth: Self.width)
                .padding(-Self.width)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    HStack(spacing: 20) {
        ForEach([Color.black, .gray, .white, .blue], id: \.self) { color in
            RoundedRectangle(cornerRadius: 6).fill(color).frame(width: 90, height: 90)
                .overlay { SelectionRing(cornerRadius: 6) }
        }
    }
    .padding(30)
}
