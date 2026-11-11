import CoreImage
import EditModel
@testable import RenderEngine
import Testing

struct VignetteRendererTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let extent = CGRect(x: 0, y: 0, width: 300, height: 200)

    private func flat(_ level: Double) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: extent)
    }

    /// Red channel of one pixel, in display (sRGB) values.
    private func sample(_ image: CIImage, _ x: Int, _ y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return Double(pixel[0]) / 255
    }

    /// Red channel of one pixel, in the linear values the pipeline computes with.
    private func linear(_ image: CIImage, _ x: Int, _ y: Int) -> Double {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        return Double(pixel[0])
    }

    private func render(_ vignette: Vignette, on image: CIImage) -> CIImage {
        RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(vignette: vignette)), to: image)
    }

    @Test func shapeFollowsTheSettings() {
        let oval = VignetteRenderer.Shape(Vignette(), aspectRatio: 1.5)
        #expect(oval.power == 2 && abs(oval.start - 0.625) < 1e-9 && abs(oval.width - 0.6) < 1e-9)
        #expect(oval.weight(x: 0, y: 0) == 0 && oval.weight(x: 1, y: 1) == 1)
        // Roundness 0 sits halfway between the frame's oval and a circle.
        #expect(oval.scaleX == 1 && abs(oval.scaleY - 0.8) < 1e-9)
        let circle = VignetteRenderer.Shape(Vignette(roundness: 1), aspectRatio: 1.5)
        #expect(circle.scaleX == 1 && abs(circle.scaleY - 1 / 1.5) < 1e-9)
        let portrait = VignetteRenderer.Shape(Vignette(roundness: 1), aspectRatio: 1 / 1.5)
        #expect(portrait.scaleY == 1 && abs(portrait.scaleX - 1 / 1.5) < 1e-9)
        let frame = VignetteRenderer.Shape(Vignette(roundness: -1), aspectRatio: 1.5)
        #expect(frame.power == 8 && frame.scaleX == 1 && frame.scaleY == 1)
        // The fade never closes: feather 0 keeps a narrow one.
        #expect(VignetteRenderer.Shape(Vignette(feather: 0), aspectRatio: 1.5).width == 0.05)
        // A higher midpoint pushes the effect outward.
        let far = VignetteRenderer.Shape(Vignette(midpoint: 1), aspectRatio: 1.5)
        #expect(far.weight(x: 0.95, y: 0) == 0 && oval.weight(x: 0.95, y: 0) > 0.1)
    }

    @Test func falloffImageMatchesTheShape() {
        for vignette in [Vignette(), Vignette(midpoint: 0.13, feather: 0.53, roundness: -0.14), Vignette(feather: 0, roundness: 1),
                         Vignette(midpoint: 0.3, feather: 0.2, roundness: -1)]
        {
            let shape = VignetteRenderer.Shape(vignette, aspectRatio: 1.5)
            let image = VignetteRenderer.falloff(shape, frame: extent).cropped(to: extent)
            for (x, y) in [(150, 100), (0, 0), (299, 199), (225, 100), (150, 20), (260, 170), (40, 150), (290, 100), (200, 60)] {
                // Pixel centers, in -1…1 across the frame.
                let expected = shape.weight(x: (Double(x) + 0.5) / 150 - 1, y: (Double(y) + 0.5) / 100 - 1)
                #expect(abs(linear(image, x, y) - expected) < 0.02, "\(vignette) at \(x), \(y)")
            }
        }
    }

    @Test func negativeAmountDarkensTheEdgesNotTheCenter() {
        let output = render(Vignette(amount: -1), on: flat(0.6))
        #expect(output.extent == extent)
        #expect(abs(sample(output, 150, 100) - 0.6) < 0.01)
        #expect(sample(output, 1, 1) < 0.02, "at full amount the corners go black")
        let half = render(Vignette(amount: -0.5), on: flat(0.6))
        // Half the light is left in the corners.
        #expect(abs(linear(half, 1, 1) - linear(flat(0.6), 1, 1) / 2) < 0.01)
        #expect(sample(half, 150, 1) > sample(half, 1, 1) + 0.03)
    }

    @Test func positiveAmountBrightensTheEdges() {
        let output = render(Vignette(amount: 1), on: flat(0.4))
        #expect(abs(sample(output, 150, 100) - 0.4) < 0.01)
        #expect(sample(output, 1, 1) > 0.85 && sample(output, 1, 1) < 1)
    }

    @Test func featherWidensTheFade() {
        let soft = render(Vignette(amount: -1, feather: 1), on: flat(0.6))
        let hard = render(Vignette(amount: -1, feather: 0), on: flat(0.6))
        // Right after the start of the effect, on the horizontal axis (the start is at 0.625).
        #expect(sample(hard, 255, 100) < 0.05)
        #expect(sample(soft, 255, 100) > 0.5)
        #expect(abs(sample(hard, 235, 100) - 0.6) < 0.01)
    }

    @Test func roundnessGoesFromTheFrameToACircle() {
        let settings = Vignette(amount: -1, midpoint: 0.6, feather: 0)
        var squared = settings, round = settings
        squared.roundness = -1
        round.roundness = 1
        // Near the middle of the top side: inside a circle as wide as the frame, outside a shape
        // that follows the frame.
        #expect(abs(sample(render(round, on: flat(0.6)), 150, 197) - 0.6) < 0.01)
        #expect(sample(render(squared, on: flat(0.6)), 150, 197) < 0.05)
        // Toward a corner, where the rounded rectangle is still clear and the oval already dark.
        #expect(abs(sample(render(squared, on: flat(0.6)), 245, 163) - 0.6) < 0.01)
        #expect(sample(render(settings, on: flat(0.6)), 245, 163) < 0.3)
    }

    @Test func highlightsResistADarkeningVignette() {
        let plain = Vignette(amount: -0.8), protected = Vignette(amount: -0.8, highlights: 1)
        let bright = flat(0.98), dark = flat(0.3)
        #expect(sample(render(plain, on: bright), 1, 1) < 0.6)
        #expect(sample(render(protected, on: bright), 1, 1) > 0.9)
        #expect(abs(sample(render(protected, on: dark), 1, 1) - sample(render(plain, on: dark), 1, 1)) < 0.01)
    }

    @Test func switchedOffOrWithoutAmountLeavesTheImageUntouched() {
        let image = flat(0.6)
        #expect(render(Vignette(isEnabled: false, amount: -1), on: image) === image)
        #expect(render(Vignette(amount: 0, feather: 0.2), on: image) === image)
    }

    @Test func followsTheCrop() {
        var recipe = EditRecipe(adjustments: AdjustmentSet(vignette: Vignette(amount: -1)))
        recipe.geometry = Geometry(crop: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let output = RenderPipeline.apply(recipe, to: flat(0.6))
        #expect(output.extent == CGRect(x: 0, y: 0, width: 150, height: 200))
        // Centered on the cropped frame, with its four corners darkened alike.
        #expect(abs(sample(output, 75, 100) - 0.6) < 0.01)
        #expect(sample(output, 1, 1) < 0.05)
        #expect(abs(sample(output, 1, 1) - sample(output, 148, 198)) < 0.02)
    }
}
