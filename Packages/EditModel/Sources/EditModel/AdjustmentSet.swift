import Foundation

/// The adjustment values of one layer. A nil field means "not touched": adding a new adjustment is
/// adding a field, with no migration. The render order is fixed by the engine, not by this struct.
public struct AdjustmentSet: Codable, Hashable, Sendable {
    /// White balance
    /// Warmer (+) or cooler (-), -1 to +1.
    public var temperature: Double?
    /// Magenta (+) or green (-), -1 to +1.
    public var tint: Double?

    /// Light
    /// Exposure compensation in EV, -3 to +3.
    public var exposure: Double?
    /// Recover (-) or lift (+) the highlights, -1 to +1.
    public var highlights: Double?
    /// Lift (+) or deepen (-) the shadows, -1 to +1.
    public var shadows: Double?
    /// Where black starts: deeper (-) clips the darkest tones, lifted (+) turns black into dark gray.
    public var blackPoint: Double?
    /// Contrast, -1 (flat) to +1 (punchy).
    public var contrast: Double?

    /// Color
    /// Saturation that spares already saturated colors, -1 to +1.
    public var vibrance: Double?
    /// Saturation, -1 (grayscale) to +1 (vivid).
    public var saturation: Double?

    /// Tone curves, after the light adjustments and before color.
    public var curves: Curves?

    /// Detail
    /// Sharpening strength, 0 to 1 (negative values soften).
    public var sharpness: Double?
    /// Luminance noise reduction, 0 to 1.
    public var noiseReduction: Double?

    /// Effects
    /// Darken (+) or brighten (-) the corners, -1 to +1.
    public var vignette: Double?
    /// Film-like grain, 0 to 1.
    public var grain: Double?
    /// Black and white conversion; nil keeps the colors.
    public var monochrome: Monochrome?

    public static let exposureRange: ClosedRange<Double> = -3 ... 3
    public static let unitRange: ClosedRange<Double> = -1 ... 1

    public init(temperature: Double? = nil, tint: Double? = nil, exposure: Double? = nil, highlights: Double? = nil,
                shadows: Double? = nil, blackPoint: Double? = nil, contrast: Double? = nil, vibrance: Double? = nil,
                saturation: Double? = nil, sharpness: Double? = nil, noiseReduction: Double? = nil, vignette: Double? = nil,
                grain: Double? = nil, monochrome: Monochrome? = nil)
    {
        self.temperature = temperature
        self.tint = tint
        self.exposure = exposure
        self.highlights = highlights
        self.shadows = shadows
        self.blackPoint = blackPoint
        self.contrast = contrast
        self.vibrance = vibrance
        self.saturation = saturation
        self.sharpness = sharpness
        self.noiseReduction = noiseReduction
        self.vignette = vignette
        self.grain = grain
        self.monochrome = monochrome
        clamp()
    }

    /// Every adjustment, in the order the engine applies them.
    public static let all: [WritableKeyPath<AdjustmentSet, Double?> & Sendable] = [
        \.temperature, \.tint, \.exposure, \.highlights, \.shadows, \.blackPoint, \.contrast, \.vibrance, \.saturation,
        \.sharpness, \.noiseReduction, \.vignette, \.grain,
    ]

    public static let positiveRange: ClosedRange<Double> = 0 ... 1

    public static func range(of keyPath: WritableKeyPath<AdjustmentSet, Double?>) -> ClosedRange<Double> {
        switch keyPath {
        case \.exposure: exposureRange
        case \.noiseReduction, \.grain: positiveRange
        default: unitRange
        }
    }

    /// True when every adjustment is absent or neutral.
    public var isIdentity: Bool {
        Self.all.allSatisfy { (self[keyPath: $0] ?? 0) == 0 } && (curves?.isIdentity ?? true) && monochrome == nil
    }

    /// Brings every value back into its range and stores neutral values as absent, so equal edits give
    /// equal documents.
    public mutating func clamp() {
        for keyPath in Self.all {
            guard let value = self[keyPath: keyPath] else { continue }
            let clamped = value.clamped(to: Self.range(of: keyPath))
            self[keyPath: keyPath] = clamped == 0 ? nil : clamped
        }
        if curves?.isIdentity == true {
            curves = nil
        }
    }

    /// Kept for call sites written against the first version.
    public static var contrastRange: ClosedRange<Double> {
        unitRange
    }

    public static var saturationRange: ClosedRange<Double> {
        unitRange
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
