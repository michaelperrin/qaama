import Foundation

/// The non-destructive edit applied to a photo: a list of adjustment values, never pixels.
///
/// Serialized as JSON and stored next to the photo (sidecar file or Photos adjustment data),
/// so the original is untouched and the edit can be reopened or reset at any time.
public struct EditRecipe: Codable, Hashable, Sendable {
    /// Bumped when the meaning of a field changes; readers refuse newer versions.
    public static let currentVersion = 1

    public var version: Int
    /// Exposure compensation in EV, from -3 to +3.
    public var exposure: Double
    /// Contrast, from -1 (flat) to +1 (punchy); 0 is neutral.
    public var contrast: Double
    /// Saturation, from -1 (grayscale) to +1 (vivid); 0 is neutral.
    public var saturation: Double

    public static let exposureRange: ClosedRange<Double> = -3 ... 3
    public static let contrastRange: ClosedRange<Double> = -1 ... 1
    public static let saturationRange: ClosedRange<Double> = -1 ... 1

    public static let identity = EditRecipe()

    public init(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0) {
        version = Self.currentVersion
        self.exposure = exposure.clamped(to: Self.exposureRange)
        self.contrast = contrast.clamped(to: Self.contrastRange)
        self.saturation = saturation.clamped(to: Self.saturationRange)
    }

    /// True when applying the recipe would leave the photo unchanged.
    public var isIdentity: Bool {
        self == .identity
    }

    // MARK: - Serialization

    public enum DecodingError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: jsonData)
        guard decoded.version <= Self.currentVersion else {
            throw DecodingError.unsupportedVersion(decoded.version)
        }
        self = EditRecipe(exposure: decoded.exposure, contrast: decoded.contrast, saturation: decoded.saturation)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
