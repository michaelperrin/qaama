import Foundation

/// The adjustment values of one layer. A nil field means "not touched": adding a new adjustment is
/// adding a field, with no migration. The render order is fixed by the engine, not by this struct.
public struct AdjustmentSet: Codable, Hashable, Sendable {
    /// Exposure compensation in EV, -3 to +3.
    public var exposure: Double?
    /// Contrast, -1 (flat) to +1 (punchy).
    public var contrast: Double?
    /// Saturation, -1 (grayscale) to +1 (vivid).
    public var saturation: Double?

    public static let exposureRange: ClosedRange<Double> = -3 ... 3
    public static let contrastRange: ClosedRange<Double> = -1 ... 1
    public static let saturationRange: ClosedRange<Double> = -1 ... 1

    public init(exposure: Double? = nil, contrast: Double? = nil, saturation: Double? = nil) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        clamp()
        normalize()
    }

    /// True when every adjustment is absent or neutral.
    public var isIdentity: Bool {
        (exposure ?? 0) == 0 && (contrast ?? 0) == 0 && (saturation ?? 0) == 0
    }

    /// Brings every value back into its range.
    public mutating func clamp() {
        exposure = exposure.map { $0.clamped(to: Self.exposureRange) }
        contrast = contrast.map { $0.clamped(to: Self.contrastRange) }
        saturation = saturation.map { $0.clamped(to: Self.saturationRange) }
        normalize()
    }

    /// A neutral value and an absent one mean the same thing; store the absent form so equal edits
    /// give equal documents.
    private mutating func normalize() {
        if exposure == 0 {
            exposure = nil
        }
        if contrast == 0 {
            contrast = nil
        }
        if saturation == 0 {
            saturation = nil
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
