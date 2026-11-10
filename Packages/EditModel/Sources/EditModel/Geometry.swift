import Foundation

/// A rectangle in unit coordinates (0…1) with the origin at the top-left, as the crop UI thinks of it.
public struct UnitRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
    /// Smallest crop allowed, as a fraction of each side.
    public static let minimumSide = 0.05

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double {
        x + width
    }

    public var maxY: Double {
        y + height
    }

    public var isFull: Bool {
        self == .full
    }

    /// Keeps the rectangle inside the unit square and no smaller than `minimumSide`.
    public func clamped() -> UnitRect {
        var rect = self
        rect.width = min(max(rect.width, Self.minimumSide), 1)
        rect.height = min(max(rect.height, Self.minimumSide), 1)
        rect.x = min(max(rect.x, 0), 1 - rect.width)
        rect.y = min(max(rect.y, 0), 1 - rect.height)
        return rect
    }
}

/// Straightening, rotation and crop. Applied before the adjustments.
///
/// The crop is expressed inside the "safe area": the largest rectangle with the image's aspect
/// ratio that fits in the straightened image without showing empty corners. Changing the angle
/// therefore keeps the crop valid and proportional.
public struct Geometry: Codable, Hashable, Sendable {
    /// Straightening in degrees, positive clockwise, -45 to +45.
    public var angle: Double
    /// Whole turns, 0 to 3, clockwise.
    public var quarterTurns: Int
    public var isFlippedHorizontally: Bool
    /// Crop inside the safe area, origin top-left.
    public var crop: UnitRect
    /// Width / height the crop is locked to, or nil for a free crop.
    public var aspectRatio: Double?

    public static let angleRange: ClosedRange<Double> = -45 ... 45
    public static let identity = Geometry()

    public init(angle: Double = 0, quarterTurns: Int = 0, isFlippedHorizontally: Bool = false, crop: UnitRect = .full, aspectRatio: Double? = nil) {
        self.angle = min(max(angle, Self.angleRange.lowerBound), Self.angleRange.upperBound)
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.isFlippedHorizontally = isFlippedHorizontally
        self.crop = crop.clamped()
        self.aspectRatio = aspectRatio
    }

    public var isIdentity: Bool {
        angle == 0 && quarterTurns == 0 && !isFlippedHorizontally && crop.isFull
    }

    /// Same geometry without the crop: what the crop tool shows while the user drags the frame.
    public var withoutCrop: Geometry {
        var copy = self
        copy.crop = .full
        return copy
    }

    /// Where a point of the original lands in the reference frame: the image once flipped, turned
    /// and straightened, before cropping. Both points are in unit coordinates, origin top-left.
    /// `width` and `height` are the original's, in pixels: straightening depends on the aspect.
    /// A point the straightening trims off comes out outside 0…1.
    public func referencePoint(fromSource point: UnitPoint2D, width: Double, height: Double) -> UnitPoint2D {
        var x = point.x, y = point.y, w = width, h = height
        if isFlippedHorizontally {
            x = 1 - x
        }
        for _ in 0 ..< quarterTurns {
            // A quarter turn clockwise: the left edge becomes the top.
            (x, y) = (1 - y, x)
            swap(&w, &h)
        }
        guard angle != 0, w > 0, h > 0 else { return UnitPoint2D(x: x, y: y) }
        let theta = angle * .pi / 180, scale = Self.inscribedScale(width: w, height: h, degrees: angle)
        // Pixels from the center, turned clockwise (y points down), then measured in the safe area.
        let px = (x - 0.5) * w, py = (y - 0.5) * h
        let rx = px * cos(theta) - py * sin(theta), ry = px * sin(theta) + py * cos(theta)
        return UnitPoint2D(x: 0.5 + rx / (w * scale), y: 0.5 + ry / (h * scale))
    }

    /// The inverse of `referencePoint(fromSource:width:height:)`; `width` and `height` are still the
    /// original's.
    public func sourcePoint(fromReference point: UnitPoint2D, width: Double, height: Double) -> UnitPoint2D {
        var x = point.x, y = point.y
        let turned = quarterTurns % 2 == 1
        let w = turned ? height : width, h = turned ? width : height
        if angle != 0, w > 0, h > 0 {
            let theta = angle * .pi / 180, scale = Self.inscribedScale(width: w, height: h, degrees: angle)
            let rx = (x - 0.5) * w * scale, ry = (y - 0.5) * h * scale
            let px = rx * cos(theta) + ry * sin(theta), py = -rx * sin(theta) + ry * cos(theta)
            x = 0.5 + px / w
            y = 0.5 + py / h
        }
        for _ in 0 ..< quarterTurns {
            (x, y) = (y, 1 - x)
        }
        if isFlippedHorizontally {
            x = 1 - x
        }
        return UnitPoint2D(x: x, y: y)
    }

    /// Scale of the largest rectangle with aspect `width : height` that fits inside that rectangle once
    /// rotated by `degrees`. 1 at 0°; a square at 45° gives 1/√2.
    public static func inscribedScale(width: Double, height: Double, degrees: Double) -> Double {
        let theta = abs(degrees) * .pi / 180
        let cosine = cos(theta), sine = sin(theta)
        guard width > 0, height > 0 else { return 1 }
        return min(width / (width * cosine + height * sine), height / (width * sine + height * cosine))
    }
}
