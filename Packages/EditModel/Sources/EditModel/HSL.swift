import Foundation

/// Hue, saturation and luminance shifts for one color range, -1 to +1 each.
public struct HSLValue: Codable, Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public static let range: ClosedRange<Double> = -1 ... 1

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue.clamped(to: Self.range)
        self.saturation = saturation.clamped(to: Self.range)
        self.luminance = luminance.clamped(to: Self.range)
    }

    public var isIdentity: Bool {
        hue == 0 && saturation == 0 && luminance == 0
    }
}

/// Selective color: eight hue ranges, each with its own hue, saturation and luminance shifts.
/// Pixels between two ranges take a blend of both; gray pixels are left alone.
public struct HSL: Codable, Hashable, Sendable {
    public enum ColorRange: String, CaseIterable, Codable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta

        /// Center hue in degrees.
        public var hue: Double {
            switch self {
            case .red: 0
            case .orange: 30
            case .yellow: 60
            case .green: 120
            case .aqua: 180
            case .blue: 240
            case .purple: 275
            case .magenta: 315
            }
        }
    }

    public var values: [ColorRange: HSLValue]

    /// Degrees of hue rotation at the end of a hue slider.
    public static let hueSpan = 30.0

    public init(values: [ColorRange: HSLValue] = [:]) {
        self.values = values.filter { !$0.value.isIdentity }
    }

    public subscript(range: ColorRange) -> HSLValue {
        get { values[range] ?? HSLValue() }
        set { values[range] = newValue.isIdentity ? nil : newValue }
    }

    public var isIdentity: Bool {
        values.isEmpty
    }

    // MARK: - Mapping

    /// Weight of each range for a hue, in degrees: 1 at the center, falling to 0 at the neighbors.
    static func weights(forHue hue: Double) -> [ColorRange: Double] {
        let ranges = ColorRange.allCases
        var result: [ColorRange: Double] = [:]
        for (index, range) in ranges.enumerated() {
            let previous = ranges[(index + ranges.count - 1) % ranges.count].hue
            let next = ranges[(index + 1) % ranges.count].hue
            let center = range.hue
            let distance = shortestDistance(from: hue, to: center)
            let halfWidth = distance >= 0 ? circularGap(from: center, to: next) : circularGap(from: previous, to: center)
            let t = abs(distance) / max(halfWidth, 1)
            if t < 1 {
                // Smoothstep for seamless blends between neighbors.
                result[range] = 1 - (3 * t * t - 2 * t * t * t)
            }
        }
        return result
    }

    private static func circularGap(from a: Double, to b: Double) -> Double {
        var gap = b - a
        while gap < 0 {
            gap += 360
        }
        return gap
    }

    private static func shortestDistance(from a: Double, to b: Double) -> Double {
        var distance = a - b
        while distance > 180 {
            distance -= 360
        }
        while distance < -180 {
            distance += 360
        }
        return distance
    }

    /// Adjusted color for an input in 0…1 RGB (display values).
    public func apply(red: Double, green: Double, blue: Double) -> (red: Double, green: Double, blue: Double) {
        guard !isIdentity else { return (red, green, blue) }
        var (h, s, l) = Self.rgbToHSL(red, green, blue)
        guard s > 0.001 else { return (red, green, blue) }
        let weights = Self.weights(forHue: h)
        var hueShift = 0.0, saturationShift = 0.0, luminanceShift = 0.0
        for (range, weight) in weights {
            guard let value = values[range] else { continue }
            hueShift += weight * value.hue * Self.hueSpan
            saturationShift += weight * value.saturation
            luminanceShift += weight * value.luminance
        }
        // Gray-ish pixels respond less: the shifts fade out with the saturation.
        let influence = min(1, s * 2)
        h = (h + hueShift * influence).truncatingRemainder(dividingBy: 360)
        if h < 0 {
            h += 360
        }
        s = (s * (1 + saturationShift * influence)).clamped(to: 0 ... 1)
        l = (l + luminanceShift * influence * 0.25 * (1 - abs(2 * l - 1) * 0.5)).clamped(to: 0 ... 1)
        return Self.hslToRGB(h, s, l)
    }

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let l = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0.00001 else { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        var h: Double = if maximum == r {
            (g - b) / delta + (g < b ? 6 : 0)
        } else if maximum == g {
            (b - r) / delta + 2
        } else {
            (r - g) / delta + 4
        }
        h *= 60
        return (h, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (red: Double, green: Double, blue: Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 {
                t += 1
            }
            if t > 1 {
                t -= 1
            }
            if t < 1 / 6 {
                return p + (q - p) * 6 * t
            }
            if t < 1 / 2 {
                return q
            }
            if t < 2 / 3 {
                return p + (q - p) * (2 / 3 - t) * 6
            }
            return p
        }
        let hue = h / 360
        return (channel(hue + 1 / 3), channel(hue), channel(hue - 1 / 3))
    }
}
