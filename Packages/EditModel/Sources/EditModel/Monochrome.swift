import Foundation

/// Black and white conversion with a channel mixer: how much each color contributes to the gray,
/// as offsets around the standard luminance weights (-1 to +1 each).
public struct Monochrome: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public static let range: ClosedRange<Double> = -1 ... 1
    /// Rec. 709 luminance weights, the neutral mix.
    public static let luminanceWeights = (red: 0.2126, green: 0.7152, blue: 0.0722)

    public init(red: Double = 0, green: Double = 0, blue: Double = 0) {
        self.red = red.clamped(to: Self.range)
        self.green = green.clamped(to: Self.range)
        self.blue = blue.clamped(to: Self.range)
    }

    /// Channel weights, normalized to sum to 1 so the overall brightness is kept.
    public var weights: (red: Double, green: Double, blue: Double) {
        let base = Self.luminanceWeights
        let raw = (base.red * (1 + red), base.green * (1 + green), base.blue * (1 + blue))
        let sum = max(raw.0 + raw.1 + raw.2, 0.0001)
        return (raw.0 / sum, raw.1 / sum, raw.2 / sum)
    }
}
