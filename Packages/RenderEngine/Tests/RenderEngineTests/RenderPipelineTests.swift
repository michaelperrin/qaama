import CoreImage
import EditModel
@testable import RenderEngine
import Testing

struct RenderPipelineTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])

    /// Average color of a 1×1 render of the image, as RGB in 0…1.
    private func color(of image: CIImage) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let red = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

    @Test func identityLeavesTheImageUntouched() {
        let output = RenderPipeline.apply(.identity, to: gray)
        #expect(output === gray)
    }

    @Test func positiveExposureBrightens() {
        let before = color(of: gray)
        let after = color(of: RenderPipeline.apply(EditRecipe(exposure: 1), to: gray))
        #expect(after.r > before.r + 0.1)
    }

    @Test func fullDesaturationGivesGray() {
        let after = color(of: RenderPipeline.apply(EditRecipe(saturation: -1), to: red))
        #expect(abs(after.r - after.g) < 0.02)
        #expect(abs(after.g - after.b) < 0.02)
    }

    @Test func disabledLayersAreSkipped() {
        var recipe = EditRecipe(exposure: 2)
        recipe.layers[0].isEnabled = false
        #expect(RenderPipeline.apply(recipe, to: gray) === gray)
    }

    @Test func factorsAreNeutralAtZero() {
        #expect(RenderPipeline.contrastFactor(0) == 1)
        #expect(RenderPipeline.saturationFactor(0) == 1)
        #expect(RenderPipeline.saturationFactor(-1) == 0)
    }
}

struct HistogramTests {
    @Test func solidGrayPeaksInOneBin() throws {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let histogram = try #require(HistogramComputer.compute(gray))
        let peak = try #require(histogram.red.firstIndex(of: 1))
        #expect((120 ... 136).contains(peak), "mid gray lands near the middle bin, got \(peak)")
        #expect(histogram.red.filter { $0 > 0 }.count <= 2)
        #expect(histogram.luminance[peak] == 1)
    }

    @Test func exposureShiftsTheHistogramRight() throws {
        let gray = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let darkHistogram = try #require(HistogramComputer.compute(gray))
        let before = try #require(darkHistogram.red.firstIndex(of: 1))
        let brighter = RenderPipeline.apply(EditRecipe(exposure: 1), to: gray)
        let brightHistogram = try #require(HistogramComputer.compute(brighter))
        let after = try #require(brightHistogram.red.firstIndex(of: 1))
        #expect(after > before)
    }

    @Test func blownOutPixelsPileUpInTheLastBin() throws {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let blown = RenderPipeline.apply(EditRecipe(exposure: 3), to: gray)
        let histogram = try #require(HistogramComputer.compute(blown))
        #expect(histogram.red.lastIndex(of: 1) == Histogram.binCount - 1)
    }

    @Test func emptyImagesGiveNoHistogram() {
        #expect(HistogramComputer.compute(CIImage.empty()) == nil)
    }
}
