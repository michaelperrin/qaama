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
