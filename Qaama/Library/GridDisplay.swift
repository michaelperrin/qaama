import LibraryKit
import SwiftUI

/// How the grid shows its thumbnails: their size, and whether a photo is cropped to a square or shown
/// whole. Both live in the preferences under these keys, so the grid comes back as it was left, and
/// are read with `@AppStorage` by the grid, the toolbar's slider and the View menu alike.
enum GridDisplay {
    /// Side of a thumbnail, in points.
    static let thumbnailSideKey = "gridThumbnailSide"
    /// A `ThumbnailFit` raw value.
    static let thumbnailFitKey = "gridThumbnailFit"

    static let sideRange: ClosedRange<Double> = 80 ... 400
    static let defaultSide: Double = 160
    /// What View › Zoom In and Zoom Out move by; the slider is continuous.
    static let zoomStep: Double = 40

    /// The next zoom step up from `side`, on the step grid, or `side` at the top of the range.
    static func zoomedIn(_ side: Double) -> Double {
        min(((side / zoomStep).rounded(.down) + 1) * zoomStep, sideRange.upperBound)
    }

    /// The next zoom step down from `side`, or `side` at the bottom of the range.
    static func zoomedOut(_ side: Double) -> Double {
        max(((side / zoomStep).rounded(.up) - 1) * zoomStep, sideRange.lowerBound)
    }

    /// Pixels to ask the source for a thumbnail of `side` points, rounded up to a step so a drag of the
    /// slider doesn't reload every visible thumbnail at each move; the same size serves the prefetch,
    /// which PhotoKit caches by exact size.
    static func requestPixels(forSide side: CGFloat, displayScale: CGFloat) -> CGSize {
        let pixels = (side * displayScale / pixelStep).rounded(.up) * pixelStep
        return CGSize(width: pixels, height: pixels)
    }

    private static let pixelStep: CGFloat = 128
}

/// The toolbar's thumbnail size slider; bound to the same preference as the View menu's Zoom In and Out.
struct ThumbnailSizeSlider: View {
    @AppStorage(GridDisplay.thumbnailSideKey) private var side = GridDisplay.defaultSide

    var body: some View {
        Slider(value: $side, in: GridDisplay.sideRange) {
            Text("Thumbnail Size")
        } minimumValueLabel: {
            Image(systemName: "square.grid.3x3").imageScale(.small)
        } maximumValueLabel: {
            Image(systemName: "square.grid.2x2").imageScale(.small)
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 140)
        // The toolbar draws its capsule on the view's bounds: without this the icons touch its edges.
        .padding(.horizontal, 8)
        .help("Thumbnail size")
    }
}

/// The toolbar's square-or-whole button; the same preference as the View menu's Thumbnails items.
struct ThumbnailFitToggle: View {
    @AppStorage(GridDisplay.thumbnailFitKey) private var fit = ThumbnailFit.fill

    var body: some View {
        Toggle(isOn: Binding(get: { fit == .fit }, set: { fit = $0 ? .fit : .fill })) {
            Label {
                Text("Whole Photos")
            } icon: {
                ThumbnailFitSymbol(photoHeight: fit == .fit ? ThumbnailFitSymbol.wholePhotoHeight : 1)
                    .fill(style: FillStyle(eoFill: true))
                    .frame(width: 16, height: 16)
                    .animation(.snappy(duration: 0.25), value: fit)
            }
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help(fit == .fit ? "Crop thumbnails to squares" : "Show whole photos")
    }
}

/// The symbol of that button: a square frame, and inside it a photo that fills it (square thumbnails)
/// or a landscape one with bands above and below (whole photos). Drawn here because SF Symbols has no
/// sign for the difference; filled with the foreground style, so it is tinted like a symbol.
nonisolated struct ThumbnailFitSymbol: Shape {
    /// Height of the photo as a fraction of the frame's inside.
    var photoHeight: CGFloat
    static let wholePhotoHeight: CGFloat = 0.6

    var animatableData: CGFloat {
        get { photoHeight }
        set { photoHeight = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        // About the stroke of an SF Symbol at the same size.
        let line = side / 13
        var path = Path()
        // The frame is the ring between these two, with the even-odd rule.
        path.addRoundedRect(in: square, cornerSize: CGSize(width: side / 5, height: side / 5))
        path.addRoundedRect(in: square.insetBy(dx: line, dy: line), cornerSize: CGSize(width: side / 5 - line, height: side / 5 - line))
        // The photo, inside the frame with a gap; it counts as a third contour, so it is filled too.
        let inside = square.insetBy(dx: 2 * line, dy: 2 * line)
        let height = inside.height * photoHeight
        path.addRoundedRect(in: CGRect(x: inside.minX, y: inside.midY - height / 2, width: inside.width, height: height),
                            cornerSize: CGSize(width: line, height: line))
        return path
    }
}
