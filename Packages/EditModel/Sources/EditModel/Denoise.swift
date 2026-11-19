import Foundation

/// How much noise is taken out of the photo as it is decoded, before anything else is applied.
///
/// An absent amount leaves what the photo gets by itself: what the RAW engine picks for the file,
/// which depends on its sensitivity, and nothing for other images. So zero is a setting of its
/// own, less than a RAW's default, and not "untouched". Only the global layer's is applied: the
/// noise is taken out of the whole original, not of what a mask selects.
public struct Denoise: Codable, Hashable, Sendable {
    /// Luminance noise reduction, 0 to 1: the grain itself.
    public var luminance: Double?
    /// Color noise reduction, 0 to 1: the colored speckles.
    public var color: Double?

    public static let range: ClosedRange<Double> = 0 ... 1

    public init(luminance: Double? = nil, color: Double? = nil) {
        self.luminance = luminance
        self.color = color
    }

    /// True when both amounts are left to the photo's defaults.
    public var isNeutral: Bool {
        luminance == nil && color == nil
    }

    var clamped: Denoise {
        Denoise(luminance: luminance?.clamped(to: Self.range), color: color?.clamped(to: Self.range))
    }
}
