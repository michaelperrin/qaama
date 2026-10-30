import Foundation

/// A point in the reference frame of masks: the straightened, uncropped image, in unit
/// coordinates with the origin at the top-left (like the crop frame).
public struct UnitPoint2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where a mask applies. Components are combined in order with their operation; the result is
/// feathered, inverted and scaled by density. Everything is described, never stored as pixels.
public struct Mask: Codable, Hashable, Sendable {
    /// Name shown in the layer list; nil shows the first component's kind.
    public var name: String?
    public var components: [MaskComponent]
    public var isInverted: Bool
    /// Edge softening, 0…1, as a fraction of the image's long edge.
    public var feather: Double
    /// Maximum opacity of the mask, 0…1.
    public var density: Double

    public init(name: String? = nil, components: [MaskComponent] = [], isInverted: Bool = false, feather: Double = 0, density: Double = 1) {
        self.name = name
        self.components = components
        self.isInverted = isInverted
        self.feather = min(max(feather, 0), 1)
        self.density = min(max(density, 0), 1)
    }

    public init(_ kind: MaskKind) {
        self.init(components: [MaskComponent(kind: kind)])
    }

    /// A mask without components selects nothing.
    public var isEmpty: Bool {
        components.isEmpty
    }

    public var displayName: String {
        name ?? components.first?.kind.displayName ?? "Mask"
    }
}

/// One building block of a mask, added to, subtracted from or intersected with the previous ones.
public struct MaskComponent: Codable, Hashable, Sendable, Identifiable {
    public enum Operation: String, Codable, Sendable, CaseIterable {
        case add, subtract, intersect
    }

    public var id: UUID
    public var operation: Operation
    public var kind: MaskKind

    public init(id: UUID = UUID(), operation: Operation = .add, kind: MaskKind) {
        self.id = id
        self.operation = operation
        self.kind = kind
    }
}

/// What a component selects. Machine-learned kinds are computed from the original by the engine;
/// the others are described by their parameters.
public enum MaskKind: Codable, Hashable, Sendable {
    /// The main subjects; `instances` picks some of them (indices from Vision), nil means all.
    case subject(instances: [Int]?)
    case background
    case people
    case sky
    /// Regions of given scene classes (grass, road, water, building…), from the segmentation model.
    case scene(classes: [String])
    case luminosity(LuminosityRange)
    case color(ColorRange)
    case linearGradient(LinearGradientMask)
    case radialGradient(RadialGradientMask)
    case brush(BrushMask)

    public var displayName: String {
        switch self {
        case .subject: "Subject"
        case .background: "Background"
        case .people: "People"
        case .sky: "Sky"
        case let .scene(classes): classes.count == 1 ? classes[0].capitalized : "Scene"
        case .luminosity: "Luminance Range"
        case .color: "Color Range"
        case .linearGradient: "Linear Gradient"
        case .radialGradient: "Radial Gradient"
        case .brush: "Brush"
        }
    }

    /// True for kinds the engine must compute with a model before rendering.
    public var needsModel: Bool {
        switch self {
        case .subject, .background, .people, .sky, .scene: true
        default: false
        }
    }
}

/// Tones between `low` and `high` (0…1), with soft edges.
public struct LuminosityRange: Codable, Hashable, Sendable {
    public var low: Double
    public var high: Double
    /// Width of the ramp on each side, 0…1.
    public var softness: Double

    public init(low: Double = 0, high: Double = 1, softness: Double = 0.1) {
        self.low = min(max(low, 0), 1)
        self.high = min(max(high, self.low), 1)
        self.softness = min(max(softness, 0), 1)
    }

    /// Weight of a luminance value, 1 inside the range, ramping down over `softness` outside.
    public func weight(_ value: Double) -> Double {
        let ramp = max(softness, 0.0001)
        if value < low {
            return max(0, 1 - (low - value) / ramp)
        }
        if value > high {
            return max(0, 1 - (value - high) / ramp)
        }
        return 1
    }
}

/// Colors around a hue, saturated enough, with soft edges.
public struct ColorRange: Codable, Hashable, Sendable {
    /// Center hue in degrees.
    public var hue: Double
    /// Half-width of the hue window in degrees.
    public var hueRange: Double
    /// Minimum saturation (0…1) for a color to count.
    public var saturationMinimum: Double
    /// Width of the ramps, 0…1 of the hue window and of the saturation axis.
    public var softness: Double

    public init(hue: Double = 210, hueRange: Double = 30, saturationMinimum: Double = 0.2, softness: Double = 0.3) {
        self.hue = hue.truncatingRemainder(dividingBy: 360) + (hue < 0 ? 360 : 0)
        self.hueRange = min(max(hueRange, 1), 180)
        self.saturationMinimum = min(max(saturationMinimum, 0), 1)
        self.softness = min(max(softness, 0), 1)
    }

    /// Weight of a color given its hue (degrees) and saturation (0…1).
    public func weight(hue: Double, saturation: Double) -> Double {
        var distance = abs(hue - self.hue).truncatingRemainder(dividingBy: 360)
        if distance > 180 {
            distance = 360 - distance
        }
        let hueRamp = max(hueRange * softness, 0.0001)
        let hueWeight = distance <= hueRange ? 1 : max(0, 1 - (distance - hueRange) / hueRamp)
        // The saturation ramp sits below the minimum, so a gray pixel is never selected.
        let saturationRamp = max(saturationMinimum * softness, 0.0001)
        let saturationWeight = saturation >= saturationMinimum ? 1 : max(0, 1 - (saturationMinimum - saturation) / saturationRamp)
        return hueWeight * saturationWeight
    }
}

/// Fully selected before `start`, fading to nothing at `end`.
public struct LinearGradientMask: Codable, Hashable, Sendable {
    public var start: UnitPoint2D
    public var end: UnitPoint2D

    public init(start: UnitPoint2D = UnitPoint2D(x: 0.5, y: 0.2), end: UnitPoint2D = UnitPoint2D(x: 0.5, y: 0.6)) {
        self.start = start
        self.end = end
    }
}

/// Selected inside an ellipse, fading out over its edge.
public struct RadialGradientMask: Codable, Hashable, Sendable {
    public var center: UnitPoint2D
    /// Radii in unit coordinates of the reference frame.
    public var radiusX: Double
    public var radiusY: Double
    /// Rotation in degrees.
    public var angle: Double
    /// Width of the fade, 0…1 of the radius.
    public var softness: Double

    public init(center: UnitPoint2D = UnitPoint2D(x: 0.5, y: 0.5), radiusX: Double = 0.3, radiusY: Double = 0.2, angle: Double = 0, softness: Double = 0.5) {
        self.center = center
        self.radiusX = max(radiusX, 0.01)
        self.radiusY = max(radiusY, 0.01)
        self.angle = angle
        self.softness = min(max(softness, 0), 1)
    }
}

/// Strokes painted by hand, in unit coordinates.
public struct BrushMask: Codable, Hashable, Sendable {
    public struct Stroke: Codable, Hashable, Sendable {
        public var points: [UnitPoint2D]
        /// Radius as a fraction of the long edge.
        public var radius: Double
        /// 0 soft to 1 hard.
        public var hardness: Double
        public var opacity: Double
        /// An erasing stroke removes from the mask.
        public var erases: Bool

        public init(points: [UnitPoint2D], radius: Double, hardness: Double = 0.5, opacity: Double = 1, erases: Bool = false) {
            self.points = points
            self.radius = radius
            self.hardness = hardness
            self.opacity = opacity
            self.erases = erases
        }
    }

    public var strokes: [Stroke]

    public init(strokes: [Stroke] = []) {
        self.strokes = strokes
    }
}
