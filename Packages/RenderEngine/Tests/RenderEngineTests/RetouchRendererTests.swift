import CoreGraphics
import CoreImage
import EditModel
import Foundation
@testable import RenderEngine
import Testing

struct RetouchRendererTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private static let width = 200, height = 160

    /// A blue-to-white gradient from top to bottom, with a red square whose top-left corner is at
    /// (`x`, `y`) counted from the top-left, 20 pixels wide.
    private func photo(squareAt x: Int, _ y: Int) throws -> CIImage {
        let width = Self.width, height = Self.height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let i = (row * width + column) * 4
                if (x ..< x + 20).contains(column), (y ..< y + 20).contains(row) {
                    bytes[i] = 230; bytes[i + 1] = 20; bytes[i + 2] = 20
                } else {
                    let t = Double(row) / Double(height), grain = Double((column &* 7919 &+ row &* 104_729) % 11)
                    bytes[i] = UInt8(60 + 120 * t + grain); bytes[i + 1] = UInt8(100 + 110 * t + grain); bytes[i + 2] = 235
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return CIImage(cgImage: image)
    }

    /// The color at a pixel counted from the top-left, 0…255.
    private func color(of image: CIImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let extent = image.extent
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: extent.minX + CGFloat(x), y: extent.maxY - CGFloat(y) - 1, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func isRed(_ color: (r: Int, g: Int, b: Int)) -> Bool {
        color.r > 200 && color.g < 60
    }

    /// One dab over the square at (`x`, `y`), wide enough to cover it.
    private func retouch(overSquareAt x: Int, _ y: Int) -> Retouch {
        Retouch(points: [UnitPoint2D(x: Double(x + 10) / Double(Self.width), y: Double(y + 10) / Double(Self.height))], radius: 16.0 / Double(Self.width))
    }

    @Test func theFillLandsWhereTheBrushPaintedAndNowhereElse() throws {
        let image = try photo(squareAt: 40, 30)
        #expect(isRed(color(of: image, x: 50, y: 40)))
        let retouch = retouch(overSquareAt: 40, 30)
        let fill = try #require(RetouchRenderer.fill(retouch, in: image, context: context))
        // The fill covers the brush's disc, a little grown, and nothing more.
        #expect(fill.extent.width < 50 && fill.extent.width > 32)
        let healed = RetouchRenderer.apply([retouch], fills: [retouch.id: fill], to: image)
        #expect(healed.extent == image.extent)
        for (x, y) in [(50, 40), (41, 31), (59, 49)] {
            let filled = color(of: healed, x: x, y: y)
            #expect(!isRed(filled) && filled.b > 200, "the square is gone at (\(x), \(y))")
        }
        // Rows count from the top: the mirrored place, and everywhere else, is as it was.
        for (x, y) in [(50, 120), (150, 40), (5, 5), (80, 40)] {
            #expect(color(of: healed, x: x, y: y) == color(of: image, x: x, y: y))
        }
        // The gradient continues: the middle of the fill is close to its row's color just outside.
        #expect(abs(color(of: healed, x: 50, y: 40).r - color(of: image, x: 100, y: 40).r) < 25)
    }

    @Test func retouchesApplyBeforeTheGeometryAndFollowIt() throws {
        let image = try photo(squareAt: 40, 30)
        let retouch = retouch(overSquareAt: 40, 30)
        var recipe = EditRecipe()
        recipe.retouches = [retouch]
        recipe.geometry = Geometry(isFlippedHorizontally: true)
        let fills = RetouchRenderer.resolveAll(recipe.retouches, image: image, context: context)
        let flippedOriginal = GeometryRenderer.apply(Geometry(isFlippedHorizontally: true), to: image)
        #expect(isRed(color(of: flippedOriginal, x: 149, y: 40)), "the square is on the other side once flipped")
        let rendered = RenderPipeline.apply(recipe, to: image, geometry: recipe.geometry, fills: fills)
        #expect(!isRed(color(of: rendered, x: 149, y: 40)))
        // Without its fill yet, a retouch shows the photo as it was.
        #expect(isRed(color(of: RenderPipeline.apply(recipe, to: image, geometry: recipe.geometry), x: 149, y: 40)))
    }

    @Test func aLaterRetouchSeesWhatTheEarlierOnesLeft() throws {
        let image = try photo(squareAt: 40, 30)
        let first = retouch(overSquareAt: 40, 30)
        // Painted right next to the first: its surroundings include what the first one filled.
        let second = Retouch(points: [UnitPoint2D(x: 75.0 / 200, y: 40.0 / 160)], radius: 12.0 / 200)
        let fills = RetouchRenderer.resolveAll([first, second], image: image, context: context)
        #expect(fills.count == 2)
        let healed = RetouchRenderer.apply([first, second], fills: fills, to: image)
        for x in stride(from: 36, through: 90, by: 3) {
            #expect(!isRed(color(of: healed, x: x, y: 40)), "no red copied back at x = \(x)")
        }
        // Reusing the fills gives the same thing as computing them.
        let reused = RetouchRenderer.resolveAll([first, second], image: image, existing: fills, context: context)
        #expect(reused[first.id] === fills[first.id] && reused[second.id] === fills[second.id])
    }

    @Test func aRegionWithNothingAroundGetsAnEmptyFill() throws {
        let image = try photo(squareAt: 40, 30)
        let everything = Retouch(points: [UnitPoint2D(x: 0.5, y: 0.5)], radius: 2)
        #expect(RetouchRenderer.fill(everything, in: image, context: context) == nil)
        let fills = RetouchRenderer.resolveAll([everything], image: image, context: context)
        #expect(fills[everything.id]?.extent.isEmpty == true)
        #expect(RetouchRenderer.apply([everything], fills: fills, to: image) === image)
        #expect(RetouchRenderer.fill(Retouch(points: [], radius: 0.1), in: image, context: context) == nil)
    }

    @Test func theRegionIsTheBrushPathRowsFromTheTop() {
        let region = RetouchRenderer.region([CGPoint(x: 20, y: 10), CGPoint(x: 60, y: 10)], radius: 5, in: CGRect(x: 0, y: 0, width: 80, height: 40), scale: 1)
        #expect(region.width == 80 && region.height == 40)
        #expect(region.mask[10 * 80 + 40] == 1 && region.mask[10 * 80 + 17] == 1 && region.mask[30 * 80 + 40] == 0)
        #expect(RetouchRenderer.tightBounds(of: region.mask, width: 80, height: 40) == CGRect(x: 15, y: 5, width: 50, height: 10))
        let half = RetouchRenderer.region([CGPoint(x: 20, y: 10)], radius: 6, in: CGRect(x: 10, y: 0, width: 40, height: 40), scale: 0.5)
        #expect(half.width == 20 && half.height == 20 && half.mask[5 * 20 + 5] == 1 && half.mask[15 * 20 + 5] == 0)
    }

    @Test func thicknessIsTheBrushRadiusForAPlainStroke() {
        // A straight stroke fills its own bounds edge to edge: its thickness is still its radius.
        let straight = [CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 50)]
        let thin = RetouchRenderer.thickness(of: straight, radius: 12, bounds: CGRect(x: 88, y: 38, width: 224, height: 24))
        #expect(abs(thin - 12) < 3)
        // Scribbled back and forth into a blob, it is as thick as the blob.
        let scribble = stride(from: 0, to: 80, by: 10).flatMap { [CGPoint(x: 100, y: 50 + Double($0)), CGPoint(x: 300, y: 50 + Double($0))] }
        let thick = RetouchRenderer.thickness(of: scribble, radius: 12, bounds: CGRect(x: 88, y: 38, width: 224, height: 94))
        #expect(thick > 35)
    }

    /// The point mapping the retouch tool relies on agrees with what the geometry renderer draws.
    @Test func geometryPointMappingMatchesTheRenderer() throws {
        let image = try photo(squareAt: 40, 30)
        let center = UnitPoint2D(x: 50.0 / 200, y: 40.0 / 160)
        for geometry in [Geometry(isFlippedHorizontally: true), Geometry(quarterTurns: 1), Geometry(angle: 8), Geometry(angle: -6, quarterTurns: 3, isFlippedHorizontally: true)] {
            let reference = GeometryRenderer.straighten(image, with: geometry)
            let mapped = geometry.referencePoint(fromSource: center, width: 200, height: 160)
            let x = Int(mapped.x * reference.extent.width), y = Int(mapped.y * reference.extent.height)
            #expect(isRed(color(of: reference, x: x, y: y)), "the square's center is where the mapping says, for \(geometry)")
        }
    }
}
