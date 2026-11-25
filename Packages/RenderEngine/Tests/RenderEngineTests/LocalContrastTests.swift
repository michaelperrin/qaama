import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel
@testable import RenderEngine
import Testing

struct LocalContrastTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let frame = CGRect(x: 0, y: 0, width: 256, height: 256)

    /// One row of the image's red channel, in linear light.
    private func row(_ image: CIImage, y: Int = 128) -> [Double] {
        let width = Int(frame.width)
        var pixels = [Float](repeating: 0, count: width * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: CGRect(x: 0, y: y, width: width, height: 1),
                       format: .RGBAf, colorSpace: linear)
        return stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) }
    }

    private func flat(_ value: Double) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: linear)!).cropped(to: frame)
    }

    /// Vertical stripes `period` pixels wide each, between two linear grays, with soft edges.
    private func stripes(period: Double, dark: Double, light: Double, sharpness: Double = 0) -> CIImage {
        let generator = CIFilter.stripesGenerator()
        generator.width = Float(period)
        generator.sharpness = Float(sharpness)
        generator.color0 = CIColor(red: dark, green: dark, blue: dark, colorSpace: linear)!
        generator.color1 = CIColor(red: light, green: light, blue: light, colorSpace: linear)!
        return generator.outputImage!.cropped(to: frame)
    }

    /// Gap between the brightest and the darkest pixel of a row, away from the image's borders.
    private func contrast(_ image: CIImage) -> Double {
        let values = row(image)[64 ..< 192]
        return values.max()! - values.min()!
    }

    private func render(_ image: CIImage, texture: Double = 0, clarity: Double = 0) -> CIImage {
        RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(texture: texture, clarity: clarity)), to: image)
    }

    @Test func luminanceIsReadInStopsFromMiddleGray() {
        #expect(abs(LocalContrast.encodedStops(ofLuminance: 0.18) - 10.0 / 14) < 1e-9)
        #expect(abs(LocalContrast.encodedStops(ofLuminance: 0.36) - 11.0 / 14) < 1e-9)
        #expect(LocalContrast.encodedStops(ofLuminance: 0) == 0)
        #expect(LocalContrast.encodedStops(ofLuminance: 100) == 1)
        // What the filters compute is the same, through the cube root and the table.
        for luminance in [0.002, 0.045, 0.18, 0.5, 1, 2] {
            let encoded = row(LocalContrast.encodedStops(of: flat(luminance)))[10]
            #expect(abs(encoded - LocalContrast.encodedStops(ofLuminance: luminance)) < 0.002, "luminance \(luminance)")
        }
    }

    @Test func theShapesFollowTheDetailAndTameStrongEdges() {
        #expect(LocalContrast.textureShape(0) == 0 && LocalContrast.clarityShape(0) == 0)
        #expect(abs(LocalContrast.textureShape(0.2) - 0.2) < 1e-9, "fine detail is taken as is")
        #expect(LocalContrast.textureShape(-0.2) == -LocalContrast.textureShape(0.2))
        #expect(abs(LocalContrast.textureShape(3) - 0.4) < 1e-9, "a strong edge gets less than a faint one's share")
        #expect(LocalContrast.clarityShape(4) == LocalContrast.clarityLimit)
        #expect(LocalContrast.midtoneWeight(stops: 0) == 1)
        #expect(abs(LocalContrast.midtoneWeight(stops: -9) - LocalContrast.clarityOutsideMidtones) < 0.001)
    }

    @Test(arguments: [0.02, 0.18, 0.7, 1.5])
    func aFlatImageIsLeftAlone(value: Double) {
        for (texture, clarity) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1), (0.6, -0.4)] {
            let output = render(flat(value), texture: texture, clarity: clarity)
            #expect(output.extent == frame)
            // Within 3 %: the smoothed copies are held in half floats, whose steps are 0.007 stop
            // apart here and which the software renderer of the tests rounds down (under 1 % on a GPU).
            let rendered = row(output)
            #expect(abs(rendered[128] - value) < value * 0.03, "texture \(texture), clarity \(clarity)")
            #expect(abs(rendered[0] - value) < value * 0.03, "the border too")
        }
    }

    @Test func textureSetsTheContrastOfFineDetail() {
        let fine = stripes(period: 2, dark: 0.16, light: 0.2, sharpness: 1)
        let before = contrast(fine)
        #expect(contrast(render(fine, texture: 1)) > before * 1.3)
        #expect(contrast(render(fine, texture: 0.5)) < contrast(render(fine, texture: 1)))
        #expect(contrast(render(fine, texture: -1)) < before * 0.8)
    }

    @Test func textureLeavesLargeShapesAlone() {
        let wide = stripes(period: 64, dark: 0.1, light: 0.3)
        let before = row(wide), after = row(render(wide, texture: 1))
        // In the middle of a stripe, far from its edges.
        #expect(abs(after[96] - before[96]) < before[96] * 0.02)
        #expect(abs(after[160] - before[160]) < before[160] * 0.02)
    }

    @Test func claritySetsTheContrastOfLargerShapes() {
        // Soft waves a few pixels wide, half a stop apart: too gentle to be edges the base keeps.
        let waves = stripes(period: 6, dark: 0.15, light: 0.21)
        let before = contrast(waves)
        #expect(contrast(render(waves, clarity: 1)) > before * 1.2)
        #expect(contrast(render(waves, clarity: -1)) < before * 0.85)
    }

    @Test func clarityKeepsItsHaloShortAlongAStrongEdge() {
        // Four stops between the two halves. A plain blur as the base would read the pixels next to
        // the edge as two stops of detail and more than double the bright side; the edge-aware base
        // follows most of the edge.
        let edge = flat(0.8).cropped(to: CGRect(x: 128, y: 0, width: 128, height: 256)).composited(over: flat(0.05))
        let before = row(edge), after = row(render(edge, clarity: 1))
        for x in [126, 130] {
            #expect(abs(after[x] - before[x]) < before[x] * 0.4, "next to the edge, at \(x)")
        }
        for x in [90, 108, 148, 166] {
            #expect(abs(after[x] - before[x]) < before[x] * 0.03, "away from the edge, at \(x)")
        }
    }

    @Test func colorsKeepTheirHue() throws {
        let color = try CIImage(color: #require(CIColor(red: 0.4, green: 0.2, blue: 0.1, colorSpace: linear))).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 256))
        let striped = color.composited(over: stripes(period: 2, dark: 0.16, light: 0.2, sharpness: 1))
        var pixel = [Float](repeating: 0, count: 4)
        context.render(render(striped, texture: 1), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 3, y: 128, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linear)
        #expect(abs(Double(pixel[0] / pixel[1]) - 2) < 0.02 && abs(Double(pixel[1] / pixel[2]) - 2) < 0.02, "one gain for the three channels")
        #expect(pixel[3] == 1)
    }

    @Test func aGroupSwitchedOffDropsThem() {
        var set = AdjustmentSet(texture: 1, clarity: 1)
        set.setEnabled(false, for: .effects)
        let image = flat(0.18)
        #expect(RenderPipeline.apply(EditRecipe(adjustments: set), to: image) === image)
    }
}
