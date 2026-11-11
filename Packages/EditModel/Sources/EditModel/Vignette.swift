import Foundation

/// Darkens or brightens the edges of the frame, with the settings photographers know from RAW
/// developers: how much, from where, how gradually, in which shape, and how much the highlights
/// resist.
///
/// Switching it off keeps the settings in the recipe, so it can be compared with and without.
public struct Vignette: Codable, Hashable, Sendable {
    /// Off leaves the photo untouched without losing the settings below.
    public var isEnabled: Bool
    /// Darken (-) or brighten (+) the edges, -1 to +1. At -1 the corners go black.
    public var amount: Double
    /// How far from the center the effect starts, 0 (close to the center) to 1 (the corners only).
    public var midpoint: Double
    /// How gradually the effect grows from where it starts, 0 to 1. Even 0 keeps a narrow fade.
    public var feather: Double
    /// The shape: -1 follows the frame as a rounded rectangle, 0 is the oval fitted to the frame,
    /// +1 a circle.
    public var roundness: Double
    /// How much the bright areas resist a darkening vignette, 0 to 1. Without effect when brightening.
    public var highlights: Double

    public static let amountRange: ClosedRange<Double> = -1 ... 1
    public static let roundnessRange: ClosedRange<Double> = -1 ... 1
    public static let unitRange: ClosedRange<Double> = 0 ... 1

    /// The defaults are what switching the vignette on for the first time gives: a visible, soft
    /// darkening.
    public init(isEnabled: Bool = true, amount: Double = -0.4, midpoint: Double = 0.5, feather: Double = 0.5,
                roundness: Double = 0, highlights: Double = 0)
    {
        self.isEnabled = isEnabled
        self.amount = amount.clamped(to: Self.amountRange)
        self.midpoint = midpoint.clamped(to: Self.unitRange)
        self.feather = feather.clamped(to: Self.unitRange)
        self.roundness = roundness.clamped(to: Self.roundnessRange)
        self.highlights = highlights.clamped(to: Self.unitRange)
    }

    /// True when applying it would leave the photo unchanged: switched off, or no amount.
    public var isNeutral: Bool {
        !isEnabled || amount == 0
    }

    /// The same vignette with every value back in its range, for documents read from disk.
    public var clamped: Vignette {
        Vignette(isEnabled: isEnabled, amount: amount, midpoint: midpoint, feather: feather, roundness: roundness,
                 highlights: highlights)
    }
}
