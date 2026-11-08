import CoreGraphics

/// How a thumbnail sits in the square the grid gives it: cropped to fill it, or whole inside it.
/// Stored as its raw value in the preferences, so the choice survives a relaunch.
public nonisolated enum ThumbnailFit: String, Sendable, Codable, CaseIterable {
    /// The photo fills the square; what overflows is cropped away.
    case fill
    /// The whole photo, scaled to fit inside the square, with empty bands on two sides.
    case fit

    /// The widest or tallest shape a request accounts for: beyond it (panoramas), the thumbnail is
    /// scaled up a little rather than asked for at a size nothing shows.
    private static let maxRequestedRatio = 4.0

    /// The pixels to ask a source for, so the thumbnail covers a square of `squarePixels` a side in
    /// this mode without being scaled up: for `fill` the short edge reaches the side, for `fit` the
    /// long edge does. `aspectRatio` is the photo's width over height; unknown dimensions count as square.
    public func requestSize(forSquare squarePixels: CGFloat, aspectRatio: Double) -> CGSize {
        switch self {
        case .fit:
            return CGSize(width: squarePixels, height: squarePixels)
        case .fill:
            let ratio = min(max(aspectRatio > 0 ? aspectRatio : 1, 1 / Self.maxRequestedRatio), Self.maxRequestedRatio)
            return ratio >= 1
                ? CGSize(width: (squarePixels * ratio).rounded(.up), height: squarePixels)
                : CGSize(width: squarePixels, height: (squarePixels / ratio).rounded(.up))
        }
    }

    /// The size the thumbnail takes on screen inside a square of `side`: the square itself for `fill`,
    /// the photo's own shape for `fit`. The grid reserves it before the pixels arrive.
    public func displaySize(inSquare side: CGFloat, aspectRatio: Double) -> CGSize {
        switch self {
        case .fill:
            return CGSize(width: side, height: side)
        case .fit:
            let ratio = aspectRatio > 0 ? aspectRatio : 1
            return ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
        }
    }
}
