import CoreGraphics
import CoreImage
import EditModel
@testable import RenderEngine
import Testing

struct DenoiseTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private static let side = 64

    /// A mid-gray square where every pixel is pushed away from gray by `noise(x, y)`, per channel.
    private func noisy(_ noise: (Int, Int) -> (r: Int, g: Int, b: Int)) -> CIImage {
        let side = Self.side
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0 ..< side {
            for x in 0 ..< side {
                let offset = noise(x, y)
                bytes[(y * side + x) * 4] = UInt8(128 + offset.r)
                bytes[(y * side + x) * 4 + 1] = UInt8(128 + offset.g)
                bytes[(y * side + x) * 4 + 2] = UInt8(128 + offset.b)
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: side * 4, size: CGSize(width: side, height: side), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// A repeatable value in -amplitude…amplitude for each pixel and channel.
    private func scatter(_ x: Int, _ y: Int, _ channel: Int, amplitude: Int) -> Int {
        var hash = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ channel &* 83_492_791)
        hash ^= hash >> 13
        hash = hash &* 1_274_126_177
        hash ^= hash >> 16
        return Int(hash % UInt32(2 * amplitude + 1)) - amplitude
    }

    /// Colored speckles: each channel on its own.
    private var colorNoise: CIImage {
        noisy { x, y in (scatter(x, y, 0, amplitude: 40), scatter(x, y, 1, amplitude: 40), scatter(x, y, 2, amplitude: 40)) }
    }

    /// Gray grain: the three channels together.
    private var grain: CIImage {
        noisy { x, y in
            let value = scatter(x, y, 0, amplitude: 12)
            return (value, value, value)
        }
    }

    /// The display values of the image's pixels, away from its border.
    private func pixels(of image: CIImage) -> [(r: Double, g: Double, b: Double)] {
        let side = Self.side
        var floats = [Float](repeating: 0, count: side * side * 4)
        context.render(image, toBitmap: &floats, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var result: [(r: Double, g: Double, b: Double)] = []
        for y in 8 ..< side - 8 {
            for x in 8 ..< side - 8 {
                let index = (y * side + x) * 4
                result.append((Double(floats[index]), Double(floats[index + 1]), Double(floats[index + 2])))
            }
        }
        return result
    }

    private func luma(_ pixel: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b
    }

    /// How far the pixels are from gray, on average.
    private func colorfulness(_ pixels: [(r: Double, g: Double, b: Double)]) -> Double {
        pixels.reduce(0) { $0 + abs($1.r - $1.g) + abs($1.g - $1.b) } / Double(pixels.count)
    }

    /// Standard deviation of the luma.
    private func roughness(_ pixels: [(r: Double, g: Double, b: Double)]) -> Double {
        let values = pixels.map(luma)
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    }

    @Test func colorNoiseGoesAndTheLumaStays() {
        let image = colorNoise
        let before = pixels(of: image)
        let after = pixels(of: DenoiseFilter.apply(DenoiseAmounts(luminance: 0, color: 1), to: image))
        #expect(colorfulness(after) < colorfulness(before) * 0.25, "the speckles are mostly gone")
        let drift = zip(before, after).map { abs(luma($0) - luma($1)) }.max() ?? 1
        #expect(drift < 0.01, "each pixel keeps its own luma: the detail is untouched")
        let half = pixels(of: DenoiseFilter.apply(DenoiseAmounts(luminance: 0, color: 0.25), to: image))
        #expect(colorfulness(half) > colorfulness(after) && colorfulness(half) < colorfulness(before), "less of the slider, less of the effect")
    }

    @Test func luminanceNoiseIsSmoothed() {
        let image = grain
        let before = pixels(of: image)
        let after = pixels(of: DenoiseFilter.apply(DenoiseAmounts(luminance: 1, color: 0), to: image))
        #expect(roughness(after) < roughness(before) * 0.6)
        #expect(colorfulness(after) < 0.01, "gray stays gray")
    }

    @Test func aFlatColorComesOutAsItWentIn() {
        let flat = CIImage(color: CIColor(red: 0.7, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        let output = DenoiseFilter.apply(DenoiseAmounts(luminance: 1, color: 1), to: flat)
        #expect(output.extent == flat.extent)
        let before = pixels(of: flat)[0], after = pixels(of: output)[0]
        #expect(abs(before.r - after.r) < 0.01 && abs(before.g - after.g) < 0.01 && abs(before.b - after.b) < 0.01)
    }

    @Test func nothingAskedIsTheOriginalItself() {
        let source = SourceImage(image: colorNoise, isRAW: false)
        #expect(source.defaultDenoise == .none)
        #expect(source.image(denoise: nil) === source.image)
        #expect(source.image(denoise: Denoise(luminance: 0, color: 0)) === source.image, "an image that isn't RAW has none by default")
        #expect(source.image(denoise: Denoise(color: 0.5)) !== source.image)
        #expect(source.amounts(of: Denoise(color: 0.5)) == DenoiseAmounts(luminance: 0, color: 0.5))
        #expect(DenoiseFilter.apply(.none, to: source.image) === source.image)
    }

    @Test func aRenderDenoisesWhatTheRecipeAsks() async {
        let source = SourceImage(image: colorNoise, isRAW: false)
        let plain = await EditRenderer.render(source: source, recipe: EditRecipe())
        #expect(plain === source.image)
        var recipe = EditRecipe(adjustments: AdjustmentSet(denoise: Denoise(color: 1)))
        let before = colorfulness(pixels(of: plain))
        #expect(await colorfulness(pixels(of: EditRenderer.render(source: source, recipe: recipe))) < before * 0.25)
        recipe.global.setEnabled(false, for: .denoise)
        #expect(await EditRenderer.render(source: source, recipe: recipe) === source.image, "switched off, the photo is decoded as by default")
    }
}
