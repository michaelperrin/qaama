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
    /// Selective color (hue, saturation, luminance per color range), after the global color controls.
    public var hsl: HSL?

    /// Detail
    /// Sharpening strength, 0 to 1 (negative values soften).
    public var sharpness: Double?
    /// Luminance noise reduction, 0 to 1.
    public var noiseReduction: Double?

    /// Effects
    /// Remove (+) or add (-) atmospheric haze, -1 to +1.
    public var dehaze: Double?
    /// Film-like grain, 0 to 1.
    public var grain: Double?
    /// Darkened or brightened corners; nil until it is first switched on.
    public var vignette: Vignette?
    /// Black and white conversion; nil until it is first switched on.
    public var monochrome: Monochrome?

    /// The groups switched off, in the order of `AdjustmentGroup`; nil when all are on, so documents
    /// that switch nothing off are what they were before the switches existed. Read and written
    /// through `isEnabled(_:)` and `setEnabled(_:for:)`.
    private var disabledGroups: [AdjustmentGroup]?

    public static let exposureRange: ClosedRange<Double> = -3 ... 3
    public static let unitRange: ClosedRange<Double> = -1 ... 1

    public init(temperature: Double? = nil, tint: Double? = nil, exposure: Double? = nil, highlights: Double? = nil,
                shadows: Double? = nil, blackPoint: Double? = nil, contrast: Double? = nil, vibrance: Double? = nil,
                saturation: Double? = nil, sharpness: Double? = nil, noiseReduction: Double? = nil, dehaze: Double? = nil,
                grain: Double? = nil, vignette: Vignette? = nil, monochrome: Monochrome? = nil)
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
        self.dehaze = dehaze
        self.grain = grain
        self.vignette = vignette
        self.monochrome = monochrome
        clamp()
    }

    /// Every single-value adjustment, in the order the engine applies them.
    public static let all: [WritableKeyPath<AdjustmentSet, Double?> & Sendable] = [
        \.temperature, \.tint, \.exposure, \.highlights, \.shadows, \.blackPoint, \.contrast, \.vibrance, \.saturation,
        \.sharpness, \.noiseReduction, \.dehaze, \.grain,
    ]

    public static let positiveRange: ClosedRange<Double> = 0 ... 1

    public static func range(of keyPath: WritableKeyPath<AdjustmentSet, Double?>) -> ClosedRange<Double> {
        switch keyPath {
        case \.exposure: exposureRange
        case \.noiseReduction, \.grain: positiveRange
        default: unitRange
        }
    }

    // MARK: - Switches

    public func isEnabled(_ group: AdjustmentGroup) -> Bool {
        !(disabledGroups ?? []).contains(group)
    }

    /// Switches a group on or off. Its values are kept either way.
    public mutating func setEnabled(_ isEnabled: Bool, for group: AdjustmentGroup) {
        let disabled = AdjustmentGroup.allCases.filter { $0 == group ? !isEnabled : !self.isEnabled($0) }
        disabledGroups = disabled.isEmpty ? nil : disabled
    }

    /// What the engine applies: the same set without the values of the groups that are off.
    public var effective: AdjustmentSet {
        guard let disabledGroups else { return self }
        var set = self
        set.disabledGroups = nil
        for group in disabledGroups {
            for keyPath in group.values {
                set[keyPath: keyPath] = nil
            }
            switch group {
            case .curves: set.curves = nil
            case .colorMixer: set.hsl = nil
            default: break
            }
        }
        return set
    }

    /// True when applying the set would leave the photo unchanged: every adjustment is absent,
    /// neutral or switched off.
    public var isIdentity: Bool {
        let set = effective
        return Self.all.allSatisfy { (set[keyPath: $0] ?? 0) == 0 } && (set.curves?.isIdentity ?? true) && (set.hsl?.isIdentity ?? true)
            && monochrome?.isEnabled != true && (vignette?.isNeutral ?? true)
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
        if hsl?.isIdentity == true {
            hsl = nil
        }
        vignette = vignette?.clamped
        // The switches in their one order, each listed once, as `setEnabled` writes them.
        if let listed = disabledGroups {
            let disabled = AdjustmentGroup.allCases.filter(listed.contains)
            disabledGroups = disabled.isEmpty ? nil : disabled
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
