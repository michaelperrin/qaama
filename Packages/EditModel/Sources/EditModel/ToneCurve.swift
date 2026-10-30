import Foundation

/// A point of a tone curve, input and output in 0…1.
public struct CurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

/// A tone curve through control points, interpolated with a monotone cubic spline so it never
/// overshoots between points (Fritsch–Carlson). Always has at least its two end points.
public struct ToneCurve: Codable, Hashable, Sendable {
    public private(set) var points: [CurvePoint]

    public static let identity = ToneCurve()
    /// Control points closer than this on the x axis are merged.
    public static let minimumSpacing = 0.02

    public init(points: [CurvePoint] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]) {
        self.points = Self.normalized(points)
    }

    /// True when every point sits on the diagonal.
    public var isIdentity: Bool {
        points.allSatisfy { abs($0.x - $0.y) < 0.0005 }
    }

    // MARK: - Editing

    /// Inserts a point, or moves the one already at that x. Returns its index.
    @discardableResult
    public mutating func insert(_ point: CurvePoint) -> Int {
        var list = points
        if let existing = list.firstIndex(where: { abs($0.x - point.x) < Self.minimumSpacing }) {
            list[existing] = CurvePoint(x: list[existing].x, y: point.y)
        } else {
            list.append(point)
        }
        points = Self.normalized(list)
        return points.firstIndex { abs($0.x - point.x) < Self.minimumSpacing } ?? 0
    }

    /// Moves a point, keeping it between its neighbors; end points only move vertically.
    public mutating func move(_ index: Int, to target: CurvePoint) {
        guard points.indices.contains(index) else { return }
        var x = target.x
        if index == 0 {
            x = 0
        } else if index == points.count - 1 {
            x = 1
        } else {
            let low = points[index - 1].x + Self.minimumSpacing
            let high = points[index + 1].x - Self.minimumSpacing
            x = min(max(x, low), high)
        }
        points[index] = CurvePoint(x: x, y: target.y)
    }

    /// Removes an interior point; the end points stay.
    public mutating func remove(at index: Int) {
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
    }

    private static func normalized(_ list: [CurvePoint]) -> [CurvePoint] {
        var sorted = list.sorted { $0.x < $1.x }
        var merged: [CurvePoint] = []
        for point in sorted {
            if let last = merged.last, point.x - last.x < minimumSpacing {
                merged[merged.count - 1] = CurvePoint(x: last.x, y: point.y)
            } else {
                merged.append(point)
            }
        }
        sorted = merged
        if sorted.first?.x != 0 {
            sorted.insert(CurvePoint(x: 0, y: sorted.first?.y ?? 0), at: 0)
        }
        if sorted.last?.x != 1 {
            sorted.append(CurvePoint(x: 1, y: sorted.last?.y ?? 1))
        }
        return sorted
    }

    // MARK: - Evaluation

    /// Output for an input in 0…1.
    public func evaluate(_ input: Double) -> Double {
        let x = min(max(input, 0), 1)
        guard points.count >= 2 else { return x }
        let tangents = Self.tangents(of: points)
        guard let upper = points.firstIndex(where: { $0.x >= x }) else { return points.last!.y }
        if upper == 0 {
            return points[0].y
        }
        let p0 = points[upper - 1], p1 = points[upper]
        let h = p1.x - p0.x
        guard h > 0 else { return p1.y }
        let t = (x - p0.x) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        let y = h00 * p0.y + h10 * h * tangents[upper - 1] + h01 * p1.y + h11 * h * tangents[upper]
        return min(max(y, 0), 1)
    }

    /// `count` evenly spaced outputs over 0…1, as a lookup table.
    public func samples(count: Int) -> [Double] {
        (0 ..< count).map { evaluate(Double($0) / Double(count - 1)) }
    }

    /// Fritsch–Carlson tangents: monotone where the data is, flat at extrema.
    private static func tangents(of points: [CurvePoint]) -> [Double] {
        let n = points.count
        var slopes = [Double](repeating: 0, count: n - 1)
        for index in 0 ..< n - 1 {
            let dx = points[index + 1].x - points[index].x
            slopes[index] = dx > 0 ? (points[index + 1].y - points[index].y) / dx : 0
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for index in 1 ..< n - 1 {
            tangents[index] = slopes[index - 1] * slopes[index] <= 0 ? 0 : (slopes[index - 1] + slopes[index]) / 2
        }
        for index in 0 ..< n - 1 where slopes[index] != 0 {
            let alpha = tangents[index] / slopes[index], beta = tangents[index + 1] / slopes[index]
            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let tau = 3 / magnitude.squareRoot()
                tangents[index] = tau * alpha * slopes[index]
                tangents[index + 1] = tau * beta * slopes[index]
            }
        }
        return tangents
    }
}

/// Tone curves per channel. The RGB curve applies to all channels, then each channel's own curve.
public struct Curves: Codable, Hashable, Sendable {
    public var rgb: ToneCurve
    public var red: ToneCurve
    public var green: ToneCurve
    public var blue: ToneCurve

    public enum Channel: String, CaseIterable, Codable, Sendable {
        case rgb, red, green, blue
    }

    public init(rgb: ToneCurve = .identity, red: ToneCurve = .identity, green: ToneCurve = .identity, blue: ToneCurve = .identity) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var isIdentity: Bool {
        rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    public subscript(channel: Channel) -> ToneCurve {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    /// Lookup tables for red, green and blue, each channel's curve composed after the RGB curve.
    public func lookupTables(count: Int) -> (red: [Double], green: [Double], blue: [Double]) {
        let master = rgb.samples(count: count)
        func table(_ curve: ToneCurve) -> [Double] {
            master.map { curve.evaluate($0) }
        }
        return (table(red), table(green), table(blue))
    }
}
