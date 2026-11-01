import CoreImage
import EditModel
@testable import RenderEngine
import Testing

struct BrushRendererTests {
    private let extent = CGRect(x: 0, y: 0, width: 3000, height: 2000)

    /// Renders to a small gray bitmap, enough to compare two paintings pixel by pixel.
    private func bytes(_ image: CIImage) -> [UInt8] {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let small = image.transformed(by: CGAffineTransform(scaleX: 300 / extent.width, y: 300 / extent.width))
        var p = [UInt8](repeating: 0, count: 300 * 200 * 4)
        context.render(small, toBitmap: &p, rowBytes: 300 * 4, bounds: CGRect(x: 0, y: 0, width: 300, height: 200), format: .RGBA8, colorSpace: nil)
        return stride(from: 0, to: p.count, by: 4).map { p[$0] }
    }

    private func wavy(_ row: Double, count: Int, erases: Bool = false, radius: Double = 0.04) -> BrushMask.Stroke {
        let points = (0 ..< count).map { UnitPoint2D(x: 0.1 + Double($0) / Double(count) * 0.8, y: row + 0.05 * sin(Double($0) / 5)) }
        return BrushMask.Stroke(points: points, radius: radius, hardness: 0.5, erases: erases)
    }

    @Test func growingAStrokePointByPointPaintsTheSameAsAtOnce() throws {
        BrushRenderer.resetCaches()
        var brush = BrushMask(strokes: [wavy(0.3, count: 40)])
        let full = wavy(0.6, count: 30)
        var growing = BrushMask.Stroke(points: [full.points[0]], radius: full.radius, hardness: full.hardness)
        brush.strokes.append(growing)
        var incremental = try #require(BrushRenderer.render(brush, extent: extent))
        for point in full.points.dropFirst() {
            growing.points.append(point)
            brush.strokes[1] = growing
            incremental = try #require(BrushRenderer.render(brush, extent: extent))
        }
        // An erasing stroke added afterwards also continues the open bitmap.
        brush.strokes.append(wavy(0.45, count: 20, erases: true, radius: 0.08))
        incremental = try #require(BrushRenderer.render(brush, extent: extent))
        let incrementalBytes = bytes(incremental)

        BrushRenderer.resetCaches()
        let fresh = try #require(BrushRenderer.render(brush, extent: extent))
        #expect(bytes(fresh) == incrementalBytes)
        #expect(incrementalBytes.contains { $0 > 200 }) // something was painted
        #expect(incrementalBytes.contains { $0 == 0 }) // and something erased or left alone
    }

    @Test func additionsDetectContinuationsOnly() {
        let a = wavy(0.3, count: 10), b = wavy(0.6, count: 10)
        var grownA = a
        grownA.points.append(UnitPoint2D(x: 0.95, y: 0.3))
        let base = BrushMask(strokes: [a])
        #expect(BrushMask(strokes: [grownA]).additions(since: base)?.map(\.from) == [10])
        #expect(BrushMask(strokes: [a, b]).additions(since: base)?.map(\.from) == [0])
        #expect(BrushMask(strokes: [grownA, b]).additions(since: base)?.map(\.from) == [10, 0])
        #expect(BrushMask(strokes: [a]).additions(since: base)?.isEmpty == true)
        #expect(BrushMask(strokes: [b]).additions(since: base) == nil) // different stroke
        #expect(BrushMask(strokes: []).additions(since: base) == nil) // stroke removed (undo)
        var harder = grownA
        harder.hardness = 0.9
        #expect(BrushMask(strokes: [harder]).additions(since: base) == nil)
        #expect(BrushMask(strokes: [b, a]).additions(since: BrushMask(strokes: [b, grownA])) == nil) // points removed
    }
}
