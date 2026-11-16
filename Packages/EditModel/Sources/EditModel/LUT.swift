import Foundation

/// A color lookup table applied to the layer: a look made in another tool (a film emulation, a
/// grade), chosen from the app's LUT library and mixed with the photo by `intensity`.
///
/// The recipe holds the table's name, not its colors: a table is tens of thousands of them, far
/// too many for a sidecar or for Photos adjustment data. A photo whose table is no longer in the
/// library renders without it, and gets its look back once a table of that name is imported again.
///
/// Switching it off keeps the choice in the recipe, so the photo can be compared with and without.
public struct LUT: Codable, Hashable, Sendable {
    /// Off leaves the photo untouched without losing the settings below.
    public var isEnabled: Bool
    /// The table's name in the LUT library; nil while none is chosen.
    public var name: String?
    /// How much of the table's result replaces the photo, 0 (none) to 1 (all of it).
    public var intensity: Double

    public static let intensityRange: ClosedRange<Double> = 0 ... 1

    public init(isEnabled: Bool = true, name: String? = nil, intensity: Double = 1) {
        self.isEnabled = isEnabled
        self.name = name
        self.intensity = intensity.clamped(to: Self.intensityRange)
    }

    /// True when applying it would leave the photo unchanged: switched off, no table, or no
    /// intensity.
    public var isNeutral: Bool {
        !isEnabled || name == nil || intensity == 0
    }

    /// The same setting with its intensity back in range, for documents read from disk.
    public var clamped: LUT {
        LUT(isEnabled: isEnabled, name: name, intensity: intensity)
    }
}
