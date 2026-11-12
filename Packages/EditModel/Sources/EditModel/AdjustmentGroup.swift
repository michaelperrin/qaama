import Foundation

/// The groups of adjustments that can be switched off as a whole, to compare a photo with and
/// without them. A group that is off keeps its values in the recipe; the engine just skips them.
///
/// Vignette and black and white are not listed: they are off until first switched on, so each
/// carries its own switch next to its settings.
public enum AdjustmentGroup: String, CaseIterable, Codable, Sendable {
    case whiteBalance, light, curves, color, colorMixer, detail, effects

    /// The single-value adjustments of the group.
    var values: [WritableKeyPath<AdjustmentSet, Double?> & Sendable] {
        switch self {
        case .whiteBalance: [\.temperature, \.tint]
        case .light: [\.exposure, \.highlights, \.shadows, \.blackPoint, \.contrast]
        case .color: [\.vibrance, \.saturation]
        case .detail: [\.sharpness, \.noiseReduction]
        case .effects: [\.dehaze, \.grain]
        case .curves, .colorMixer: []
        }
    }
}
