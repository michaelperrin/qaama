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

    @Test func warmerTemperatureRaisesRedOverBlue() {
        let neutral = color(of: gray)
        let warm = color(of: RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(temperature: 1)), to: gray))
        #expect(warm.r - warm.b > neutral.r - neutral.b + 0.05)
        let cool = color(of: RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(temperature: -1)), to: gray))
        #expect(cool.b - cool.r > neutral.b - neutral.r + 0.05)
    }

    @Test func shadowsLiftDarkTones() {
        let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let before = color(of: dark)
        let after = color(of: RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(shadows: 1)), to: dark))
        #expect(after.r > before.r + 0.03)
    }

    @Test func highlightsRecoverBrightTones() {
        let bright = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let before = color(of: bright)
        let recovered = color(of: RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(highlights: -1)), to: bright))
        #expect(recovered.r < before.r - 0.03)
    }

    @Test func blackPointClipsOrLiftsTheDarkEnd() {
        let dark = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let deeper = color(of: RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(blackPoint: -1)), to: dark))
        #expect(deeper.r < 0.01, "the darkest tones become black")
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let lifted = color(of: RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(blackPoint: 1)), to: black))
        #expect(lifted.r > 0.1, "black turns into dark gray")
    }

    @Test func vibranceIncreasesSaturation() {
        let before = color(of: red)
        let after = color(of: RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(vibrance: 1)), to: red))
        #expect(after.r - after.g > before.r - before.g)
    }

    @Test func vignetteDarkensCornersNotTheCenter() {
        let flat = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        let output = RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(vignette: 1)), to: flat)
        func sample(_ x: Int, _ y: Int) -> Double {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return Double(pixel[0]) / 255
        }
        #expect(sample(2, 2) < sample(100, 50) - 0.05)
        #expect(output.extent == flat.extent)
    }

    @Test func detailAdjustmentsKeepTheExtent() {
        let output = RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(sharpness: -1, noiseReduction: 1)), to: gray)
        #expect(output.extent == gray.extent)
        #expect(RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(sharpness: 1)), to: gray).extent == gray.extent)
    }

    @Test func curvesLiftMidtonesAndRespectChannels() {
        var set = AdjustmentSet()
        var curves = Curves()
        curves.rgb.insert(CurvePoint(x: 0.5, y: 0.75))
        set.curves = curves
        let before = color(of: gray)
        let lifted = color(of: RenderPipeline.apply(EditRecipe(adjustments: set), to: gray))
        #expect(lifted.r > before.r + 0.15 && abs(lifted.r - lifted.b) < 0.02)

        var redOnly = Curves()
        redOnly.red.insert(CurvePoint(x: 0.5, y: 0.25))
        set.curves = redOnly
        let tinted = color(of: RenderPipeline.apply(EditRecipe(adjustments: set), to: gray))
        #expect(tinted.r < before.r - 0.15 && abs(tinted.g - before.g) < 0.02)
    }

    @Test func monochromeRemovesColorAndHonorsTheMix() {
        var set = AdjustmentSet()
        set.monochrome = Monochrome()
        let gray = color(of: RenderPipeline.apply(EditRecipe(adjustments: set), to: red))
        #expect(abs(gray.r - gray.g) < 0.02 && abs(gray.g - gray.b) < 0.02)
        set.monochrome = Monochrome(red: 1, green: -1, blue: -1)
        let redFiltered = color(of: RenderPipeline.apply(EditRecipe(adjustments: set), to: red))
        #expect(redFiltered.r > gray.r + 0.1, "a red filter brightens red subjects")
    }

    @Test func grainAddsTextureWithoutChangingTheExtent() throws {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let output = RenderPipeline.apply(EditRecipe(adjustments: AdjustmentSet(grain: 1)), to: flat)
        #expect(output.extent == flat.extent)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        context.render(output, toBitmap: &pixels, rowBytes: 64 * 4, bounds: flat.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let reds = stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) / 255 }
        let mean = reds.reduce(0, +) / Double(reds.count)
        let spread = try #require(reds.max()) - #require(reds.min())
        #expect(spread > 0.05, "grain varies from pixel to pixel")
        #expect(abs(mean - 0.5) < 0.1, "grain keeps the overall brightness")
    }

    @Test func selectiveColorDesaturatesOnlyItsRange() {
        var set = AdjustmentSet()
        var hsl = HSL()
        hsl[.red] = HSLValue(saturation: -1)
        set.hsl = hsl
        let recipe = EditRecipe(adjustments: set)
        let redOut = color(of: RenderPipeline.apply(recipe, to: red))
        #expect(abs(redOut.r - redOut.g) < 0.05, "red is desaturated through the cube")
        let green = CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let greenOut = color(of: RenderPipeline.apply(recipe, to: green))
        #expect(greenOut.g - greenOut.r > 0.5, "green keeps its saturation")
    }

    @Test func identityCubeIsTransparent() {
        let cube = ColorCube.data(dimension: 9) { ($0, $1, $2) }
        let output = ColorCube.apply(cube, dimension: 9, to: red)
        let before = color(of: red), after = color(of: output)
        #expect(abs(before.r - after.r) < 0.02 && abs(before.g - after.g) < 0.02)
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

struct GeometryRendererTests {
    private let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))

    @Test func cropsInsideTheSafeAreaWithTopLeftOrigin() {
        let geometry = Geometry(crop: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let output = GeometryRenderer.apply(geometry, to: image)
        #expect(output.extent == CGRect(x: 0, y: 0, width: 150, height: 100))
    }

    @Test func straighteningShrinksToTheInscribedRectangle() {
        let output = GeometryRenderer.apply(Geometry(angle: 10), to: image)
        let scale = Geometry.inscribedScale(width: 300, height: 200, degrees: 10)
        #expect(abs(output.extent.width - (300 * scale).rounded(.down)) <= 1)
        #expect(abs(output.extent.width / output.extent.height - 1.5) < 0.02, "the aspect ratio is kept")
        #expect(output.extent.origin == .zero)
    }

    @Test func quarterTurnsSwapTheSides() {
        let output = GeometryRenderer.apply(Geometry(quarterTurns: 1), to: image)
        #expect(output.extent.size == CGSize(width: 200, height: 300))
        #expect(GeometryRenderer.apply(Geometry(quarterTurns: 2), to: image).extent.size == CGSize(width: 300, height: 200))
    }

    @Test func recipeAppliesGeometryBeforeAdjustments() {
        var recipe = EditRecipe(exposure: 1)
        recipe.geometry = Geometry(crop: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(RenderPipeline.apply(recipe, to: image).extent.width == 150)
        #expect(RenderPipeline.apply(recipe, to: image, geometry: nil).extent.width == 300)
    }
}

struct MaskRendererTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let flat = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))

    /// Masks are weights, not colors: read them back linearly, without the sRGB encoding.
    private func gray(_ image: CIImage, x: Int, y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        return Double(pixel[0]) / 255
    }

    @Test func linearGradientSelectsOneSide() throws {
        // Selected at the top (unit y 0.2), fading out toward the bottom (unit y 0.6).
        let mask = try #require(MaskRenderer.render(Mask(.linearGradient(LinearGradientMask())), reference: flat))
        #expect(gray(mask, x: 100, y: 95) > 0.95, "top of the image, Core Image y up")
        #expect(gray(mask, x: 100, y: 5) < 0.05, "bottom of the image")
    }

    @Test func radialGradientIsBrightAtItsCenterAndDarkOutside() throws {
        let radial = RadialGradientMask(center: UnitPoint2D(x: 0.25, y: 0.5), radiusX: 0.15, radiusY: 0.3, angle: 0, softness: 0.5)
        let mask = try #require(MaskRenderer.render(Mask(.radialGradient(radial)), reference: flat))
        #expect(gray(mask, x: 50, y: 50) > 0.95)
        #expect(gray(mask, x: 190, y: 50) < 0.05)
    }

    @Test func luminosityAndColorRangesPickTheirTones() throws {
        let half = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
            .composited(over: CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let darks = try #require(MaskRenderer.render(Mask(.luminosity(LuminosityRange(low: 0, high: 0.3, softness: 0.05))), reference: half))
        #expect(gray(darks, x: 50, y: 50) > 0.9 && gray(darks, x: 150, y: 50) < 0.1)

        let redAndBlue = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
            .composited(over: CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let blues = try #require(MaskRenderer.render(Mask(.color(ColorRange(hue: 230, hueRange: 30))), reference: redAndBlue))
        #expect(gray(blues, x: 150, y: 50) > 0.9 && gray(blues, x: 50, y: 50) < 0.1)
    }

    @Test func operationsFeatherInvertAndDensity() throws {
        var mask = Mask(.linearGradient(LinearGradientMask(start: UnitPoint2D(x: 0.5, y: 0.1), end: UnitPoint2D(x: 0.5, y: 0.2))))
        mask.components.append(MaskComponent(operation: .subtract, kind: .luminosity(LuminosityRange(low: 0, high: 1, softness: 0))))
        let subtracted = try #require(MaskRenderer.render(mask, reference: flat))
        #expect(gray(subtracted, x: 100, y: 95) < 0.05, "subtracting everything leaves nothing")

        mask.components.removeLast()
        mask.isInverted = true
        let inverted = try #require(MaskRenderer.render(mask, reference: flat))
        #expect(gray(inverted, x: 100, y: 95) < 0.05 && gray(inverted, x: 100, y: 5) > 0.95)

        mask.isInverted = false
        mask.density = 0.5
        let dim = try #require(MaskRenderer.render(mask, reference: flat))
        #expect(abs(gray(dim, x: 100, y: 95) - 0.5) < 0.1)

        mask.density = 1
        let hard = try #require(MaskRenderer.render(mask, reference: flat))
        mask.feather = 0.5
        let soft = try #require(MaskRenderer.render(mask, reference: flat))
        // The gradient ends at unit y 0.2 (pixel row 80, Core Image y up); a few rows below, only the
        // feathered mask still has something.
        #expect(gray(hard, x: 100, y: 74) < 0.02)
        #expect(gray(soft, x: 100, y: 74) > 0.03 && gray(soft, x: 100, y: 74) < 0.9, "feathering spreads the edge")
    }

    @Test func maskedLayerChangesOnlyItsRegionAndSurvivesCropping() {
        var recipe = EditRecipe()
        var layer = AdjustmentLayer(mask: Mask(.linearGradient(LinearGradientMask(start: UnitPoint2D(x: 0.5, y: 0.3), end: UnitPoint2D(x: 0.5, y: 0.31)))))
        layer.adjustments.exposure = 2
        recipe.layers.append(layer)
        let output = RenderPipeline.apply(recipe, to: flat)
        #expect(gray(output, x: 100, y: 90) > gray(flat, x: 100, y: 90) * 2, "top rows are brightened (+2 EV)")
        #expect(abs(gray(output, x: 100, y: 10) - gray(flat, x: 100, y: 10)) < 0.02, "bottom rows are untouched")

        // Cropping to the bottom half afterwards must not drag the mask along.
        recipe.geometry = Geometry(crop: UnitRect(x: 0, y: 0.5, width: 1, height: 0.5))
        let cropped = RenderPipeline.apply(recipe, to: flat)
        #expect(cropped.extent.height == 50)
        #expect(abs(gray(cropped, x: 100, y: 45) - gray(flat, x: 100, y: 10)) < 0.02, "the kept half was never under the mask")
    }
}
