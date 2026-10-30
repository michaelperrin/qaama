@testable import EditModel
import Foundation
import Testing

struct EditRecipeTests {
    @Test func defaultRecipeIsIdentity() {
        #expect(EditRecipe().isIdentity)
        #expect(EditRecipe(exposure: 0.5).layers.count == 1)
        #expect(!EditRecipe(exposure: 0.5).isIdentity)
        var disabled = EditRecipe(exposure: 0.5)
        disabled.layers[0].isEnabled = false
        #expect(disabled.isIdentity)
    }

    @Test func clampsAndNormalizesValues() {
        let set = AdjustmentSet(exposure: 10, contrast: -5, saturation: 0)
        #expect(set.exposure == 3 && set.contrast == -1)
        #expect(set.saturation == nil, "a neutral value is stored as absent")
        #expect(AdjustmentSet(exposure: 0) == AdjustmentSet())
        #expect(AdjustmentSet(temperature: 4).temperature == 1)
        #expect(AdjustmentSet.all.count == 14)
        #expect(AdjustmentSet(noiseReduction: -1).noiseReduction == nil, "noise reduction has no negative side")
        #expect(AdjustmentSet.range(of: \.exposure) == -3 ... 3 && AdjustmentSet.range(of: \.shadows) == -1 ... 1)
    }

    @Test func newAdjustmentsRoundTripAndCountTowardIdentity() throws {
        let set = AdjustmentSet(temperature: 0.3, tint: -0.2, highlights: -0.5, shadows: 0.4, vibrance: 0.6)
        #expect(!set.isIdentity)
        let recipe = EditRecipe(adjustments: set)
        let reloaded = try EditRecipe(jsonData: recipe.jsonData())
        #expect(reloaded.global == set)
        #expect(try String(decoding: recipe.jsonData(), as: UTF8.self).contains("\"highlights\":-0.5"))
    }

    @Test func roundTripsThroughJSON() throws {
        var recipe = EditRecipe(exposure: 1.25, contrast: -0.3)
        var skyMask = Mask(.sky)
        skyMask.isInverted = true
        recipe.layers.append(AdjustmentLayer(mask: skyMask, adjustments: AdjustmentSet(saturation: 0.4)))
        let data = try recipe.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\":2") && text.contains("\"layers\":["))
        #expect(text.contains("\"exposure\":1.25") && !text.contains("saturation\":0,"))
        #expect(text.contains("\"sky\""))

        let reloaded = try EditRecipe(jsonData: data)
        #expect(reloaded == recipe)
        #expect(reloaded.global.exposure == 1.25)
        #expect(reloaded.layers[1].mask?.components.first?.kind == .sky)
    }

    @Test func globalLayerIsEditableInPlace() {
        var recipe = EditRecipe()
        recipe.global.exposure = 2
        #expect(recipe.layers[0].adjustments.exposure == 2)
        recipe.layers = []
        recipe.global.contrast = 0.5
        #expect(recipe.layers.count == 1 && recipe.global.contrast == 0.5)
    }

    @Test func rejectsOtherVersions() {
        let newer = Data(#"{"version":99,"layers":[]}"#.utf8)
        #expect(throws: EditRecipe.DecodingError.unsupportedVersion(99)) { try EditRecipe(jsonData: newer) }
        let old = Data(#"{"version":1,"exposure":0.5,"contrast":0,"saturation":0}"#.utf8)
        #expect(throws: EditRecipe.DecodingError.unsupportedVersion(1)) { try EditRecipe(jsonData: old) }
        let missing = Data(#"{"layers":[]}"#.utf8)
        #expect(throws: EditRecipe.DecodingError.unsupportedVersion(0)) { try EditRecipe(jsonData: missing) }
    }

    @Test func readingClampsOutOfRangeValues() throws {
        let data = Data(#"{"version":2,"layers":[{"id":"6F0E6C5A-0000-4000-8000-000000000000","isEnabled":true,"adjustments":{"exposure":40}}]}"#.utf8)
        #expect(try EditRecipe(jsonData: data).global.exposure == 3)
    }
}

struct GeometryTests {
    @Test func identityAndClamping() {
        #expect(Geometry().isIdentity)
        let geometry = Geometry(angle: 90, quarterTurns: 5, crop: UnitRect(x: 0.9, y: -1, width: 0.5, height: 3))
        #expect(geometry.angle == 45 && geometry.quarterTurns == 1)
        #expect(geometry.crop == UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(!geometry.isIdentity && geometry.withoutCrop.crop.isFull)
    }

    @Test func inscribedScale() {
        #expect(Geometry.inscribedScale(width: 300, height: 200, degrees: 0) == 1)
        let square = Geometry.inscribedScale(width: 100, height: 100, degrees: 45)
        #expect(abs(square - 1 / 2.0.squareRoot()) < 0.0001)
        let landscape = Geometry.inscribedScale(width: 300, height: 200, degrees: 10)
        #expect(landscape < 1 && landscape > 0.8)
        #expect(Geometry.inscribedScale(width: 300, height: 200, degrees: -10) == landscape)
    }

    @Test func geometryRoundTripsAndCountsTowardIdentity() throws {
        var recipe = EditRecipe()
        #expect(recipe.isIdentity)
        recipe.geometry = Geometry(angle: 2.5, crop: UnitRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), aspectRatio: 1.5)
        #expect(!recipe.isIdentity)
        let reloaded = try EditRecipe(jsonData: recipe.jsonData())
        #expect(reloaded.geometry == recipe.geometry)
        recipe.geometry = Geometry()
        #expect(try EditRecipe(jsonData: recipe.jsonData()).geometry == nil, "an identity geometry is dropped on read")
    }
}

struct MonochromeTests {
    @Test func weightsStayNormalized() {
        let neutral = Monochrome().weights
        #expect(abs(neutral.red + neutral.green + neutral.blue - 1) < 0.0001)
        #expect(abs(neutral.green - 0.7152) < 0.0001)
        let redFilter = Monochrome(red: 1, blue: -1).weights
        #expect(redFilter.red > neutral.red && redFilter.blue < 0.0001)
        #expect(abs(redFilter.red + redFilter.green + redFilter.blue - 1) < 0.0001)
        #expect(Monochrome(red: 5).red == 1)
    }

    @Test func monochromeCountsTowardIdentityAndRoundTrips() throws {
        var set = AdjustmentSet()
        set.monochrome = Monochrome()
        #expect(!set.isIdentity, "turning black and white on is an edit even with a neutral mix")
        let reloaded = try EditRecipe(jsonData: EditRecipe(adjustments: set).jsonData())
        #expect(reloaded.global.monochrome == Monochrome())
        #expect(AdjustmentSet(grain: 2).grain == 1 && AdjustmentSet(grain: -1).grain == nil)
    }
}

struct HSLTests {
    @Test func colorSpaceConversionsRoundTrip() {
        let (h, s, l) = HSL.rgbToHSL(0.8, 0.2, 0.2)
        #expect(abs(h) < 0.001 && s > 0.5 && abs(l - 0.5) < 0.001)
        let back = HSL.hslToRGB(h, s, l)
        #expect(abs(back.red - 0.8) < 0.001 && abs(back.green - 0.2) < 0.001)
        let gray = HSL.rgbToHSL(0.4, 0.4, 0.4)
        #expect(gray.1 == 0)
    }

    @Test func weightsBlendBetweenNeighbors() {
        let onRed = HSL.weights(forHue: 0)
        #expect(abs((onRed[.red] ?? 0) - 1) < 0.001 && onRed[.orange] == nil)
        let between = HSL.weights(forHue: 15)
        #expect((between[.red] ?? 0) > 0.4 && (between[.orange] ?? 0) > 0.4 && between[.yellow] == nil)
        let magentaSide = HSL.weights(forHue: 340)
        #expect((magentaSide[.magenta] ?? 0) > 0 && (magentaSide[.red] ?? 0) > 0, "the wheel wraps around")
    }

    @Test func adjustsOnlyTheTargetedRange() {
        var hsl = HSL()
        hsl[.red] = HSLValue(saturation: -1)
        let red = hsl.apply(red: 0.8, green: 0.2, blue: 0.2)
        #expect(abs(red.red - red.green) < 0.01, "red loses its saturation")
        let green = hsl.apply(red: 0.2, green: 0.8, blue: 0.2)
        #expect(abs(green.green - 0.8) < 0.001, "green is untouched")
        hsl = HSL()
        hsl[.red] = HSLValue(hue: 1)
        let shifted = hsl.apply(red: 0.8, green: 0.2, blue: 0.2)
        #expect(shifted.green > 0.2 + 0.1 && abs(shifted.blue - 0.2) < 0.01, "red turns toward orange")
        hsl = HSL()
        hsl[.blue] = HSLValue(luminance: 1)
        let brighter = hsl.apply(red: 0.2, green: 0.2, blue: 0.8)
        #expect(brighter.blue + brighter.red > 1.0)
        #expect(hsl.apply(red: 0.5, green: 0.5, blue: 0.5) == (0.5, 0.5, 0.5), "gray is left alone")
    }

    @Test func hslCountsTowardIdentityAndRoundTrips() throws {
        var set = AdjustmentSet()
        set.hsl = HSL()
        set.clamp()
        #expect(set.hsl == nil && set.isIdentity)
        var hsl = HSL()
        hsl[.aqua] = HSLValue(hue: 0.3, saturation: 0.2)
        set.hsl = hsl
        #expect(!set.isIdentity)
        let reloaded = try EditRecipe(jsonData: EditRecipe(adjustments: set).jsonData())
        #expect(reloaded.global.hsl == hsl)
    }
}

struct ToneCurveTests {
    @Test func identityPassesInputsThrough() {
        let curve = ToneCurve()
        #expect(curve.isIdentity)
        #expect(abs(curve.evaluate(0.3) - 0.3) < 0.0001)
        #expect(curve.samples(count: 3) == [0, 0.5, 1])
    }

    @Test func interpolatesMonotonicallyThroughPoints() {
        var curve = ToneCurve()
        curve.insert(CurvePoint(x: 0.5, y: 0.7))
        #expect(!curve.isIdentity && curve.points.count == 3)
        #expect(abs(curve.evaluate(0.5) - 0.7) < 0.0001)
        #expect(curve.evaluate(0.25) > 0.25 && curve.evaluate(0.25) < 0.7)
        let samples = curve.samples(count: 64)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 0.0001 }, "no overshoot between points")
    }

    @Test func editingKeepsEndPointsAndSpacing() {
        var curve = ToneCurve()
        let index = curve.insert(CurvePoint(x: 0.4, y: 0.5))
        curve.move(index, to: CurvePoint(x: 0.99, y: 0.9))
        #expect(curve.points[index].x <= 1 - ToneCurve.minimumSpacing)
        curve.move(0, to: CurvePoint(x: 0.5, y: 0.2))
        #expect(curve.points[0] == CurvePoint(x: 0, y: 0.2), "end points only move vertically")
        curve.remove(at: 0)
        #expect(curve.points.count == 3, "end points can't be removed")
        curve.remove(at: index)
        #expect(curve.points.count == 2)
        #expect(ToneCurve(points: [CurvePoint(x: 0.5, y: 0.5)]).points.count == 3, "missing end points are added")
    }

    @Test func curvesComposeAndCountTowardIdentity() throws {
        var curves = Curves()
        #expect(curves.isIdentity)
        curves.rgb.insert(CurvePoint(x: 0.5, y: 0.6))
        curves.red.insert(CurvePoint(x: 0.5, y: 0.4))
        let tables = curves.lookupTables(count: 3)
        #expect(abs(tables.green[1] - 0.6) < 0.0001)
        #expect(tables.red[1] < tables.green[1], "the red curve applies after the RGB curve")
        var set = AdjustmentSet()
        set.curves = curves
        #expect(!set.isIdentity)
        let reloaded = try EditRecipe(jsonData: EditRecipe(adjustments: set).jsonData())
        #expect(reloaded.global.curves == curves)
        set.curves = Curves()
        set.clamp()
        #expect(set.curves == nil, "identity curves are dropped")
    }
}

struct MaskTests {
    @Test func kindsRoundTripThroughJSON() throws {
        let kinds: [MaskKind] = [
            .subject(instances: [0, 2]), .background, .people, .sky, .scene(classes: ["grass", "road"]),
            .luminosity(LuminosityRange(low: 0.2, high: 0.8, softness: 0.1)),
            .color(ColorRange(hue: 200, hueRange: 25, saturationMinimum: 0.3, softness: 0.2)),
            .linearGradient(LinearGradientMask()),
            .radialGradient(RadialGradientMask(center: UnitPoint2D(x: 0.3, y: 0.4), radiusX: 0.2, radiusY: 0.1, angle: 15, softness: 0.4)),
            .brush(BrushMask(strokes: [BrushMask.Stroke(points: [UnitPoint2D(x: 0.1, y: 0.1), UnitPoint2D(x: 0.2, y: 0.2)], radius: 0.05)])),
        ]
        var mask = Mask(name: "Test", components: kinds.map { MaskComponent(kind: $0) }, feather: 0.2, density: 0.8)
        mask.components[1].operation = .subtract
        var recipe = EditRecipe()
        recipe.layers.append(AdjustmentLayer(mask: mask, adjustments: AdjustmentSet(exposure: 0.5)))
        let reloaded = try EditRecipe(jsonData: recipe.jsonData())
        #expect(reloaded.layers[1].mask == mask)
        #expect(reloaded.maskedLayers.count == 1)
        #expect(mask.displayName == "Test" && Mask(.sky).displayName == "Sky" && Mask(.scene(classes: ["grass"])).displayName == "Grass")
        #expect(MaskKind.sky.needsModel && !MaskKind.background.needsModel == false && !MaskKind.linearGradient(LinearGradientMask()).needsModel)
    }

    @Test func emptyMaskedLayersDontCountAsEdits() {
        var recipe = EditRecipe()
        recipe.layers.append(AdjustmentLayer(mask: Mask(), adjustments: AdjustmentSet(exposure: 1)))
        #expect(recipe.isIdentity, "a layer whose mask selects nothing changes nothing")
        recipe.layers[1].mask = Mask(.linearGradient(LinearGradientMask()))
        #expect(!recipe.isIdentity)
    }

    @Test func rangeWeightsRampSoftly() {
        let tones = LuminosityRange(low: 0.4, high: 0.6, softness: 0.2)
        #expect(tones.weight(0.5) == 1 && abs(tones.weight(0.3) - 0.5) < 0.0001 && tones.weight(0.1) == 0)
        let blues = ColorRange(hue: 210, hueRange: 30, saturationMinimum: 0.2, softness: 0.5)
        #expect(blues.weight(hue: 220, saturation: 0.8) == 1)
        #expect(blues.weight(hue: 30, saturation: 0.8) == 0, "orange is far from blue")
        #expect(blues.weight(hue: 210, saturation: 0) == 0, "gray doesn't count")
        #expect(ColorRange(hue: -10).hue == 350)
    }
}
