import Foundation

/// Something painted out of the photo: the path the brush followed over it. The engine fills that
/// region from what surrounds it. Like everything in a recipe this is a description, not pixels: the
/// fill is computed again from the original whenever it is needed, and comes out the same.
///
/// Points are in the original image's unit coordinates (origin top-left), before any geometry, so a
/// retouch stays on what it removed when the photo is later turned, straightened or cropped.
/// Retouches apply in order: each one sees the photo as the earlier ones left it.
public struct Retouch: Codable, Hashable, Sendable, Identifiable {
    /// The fill the engine currently computes for new retouches.
    public static let currentAlgorithm = 1
    /// Brush radii offered by the tool, as fractions of the long edge.
    public static let radiusRange: ClosedRange<Double> = 0.002 ... 0.1

    public var id: UUID
    public var points: [UnitPoint2D]
    /// Radius of the brush, as a fraction of the original's long edge.
    public var radius: Double
    /// The fill this retouch was made with. A later, better fill gets another number, so that
    /// photos retouched before it keep the result their owner saw.
    public var algorithm: Int

    public init(id: UUID = UUID(), points: [UnitPoint2D], radius: Double, algorithm: Int = Retouch.currentAlgorithm) {
        self.id = id
        self.points = points
        self.radius = radius
        self.algorithm = algorithm
    }
}
