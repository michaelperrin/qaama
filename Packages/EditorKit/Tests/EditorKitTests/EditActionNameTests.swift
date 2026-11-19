import EditModel
@testable import EditorKit
import Foundation
import Testing

struct EditActionNameTests {
    /// The name of the change `edit` makes to `recipe`.
    private func name(of edit: (inout EditRecipe) -> Void, from recipe: EditRecipe = .identity) -> String {
        var edited = recipe
        edit(&edited)
        return EditActionName.describing(from: recipe, to: edited)
    }

    @Test func slidersAreNamedAfterTheirSetting() {
        #expect(name { $0.global.exposure = 1 } == "Exposure")
        #expect(name { $0.global.blackPoint = -0.2 } == "Black Point")
        #expect(name { $0.global.denoise = Denoise(luminance: 0.4) } == "Luminance Noise Reduction")
        #expect(name(of: { $0.global.denoise?.color = 0 }, from: EditRecipe(adjustments: AdjustmentSet(denoise: Denoise(luminance: 0.4))))
            == "Color Noise Reduction")
        #expect(name { $0.global.setEnabled(false, for: .denoise) } == "Turn Off Denoise")
        // Back to neutral is the same setting.
        #expect(name(of: { $0.global.exposure = nil }, from: EditRecipe(exposure: 1)) == "Exposure")
    }

    @Test func switchesSayWhichWayTheyWent() {
        #expect(name { $0.global.setEnabled(false, for: .light) } == "Turn Off Light")
        var off = EditRecipe.identity
        off.global.setEnabled(false, for: .whiteBalance)
        #expect(name(of: { $0.global.setEnabled(true, for: .whiteBalance) }, from: off) == "Turn On White Balance")
        // Switched on for the first time, with its default settings: one change.
        #expect(name { $0.global.vignette = Vignette() } == "Turn On Vignette")
        #expect(name { $0.global.monochrome = Monochrome() } == "Turn On Black & White")
        #expect(name { $0.global.lut = LUT() } == "Turn On LUT")
    }

    @Test func effectSettingsAreNamedWithTheirEffect() {
        let vignetted = EditRecipe(adjustments: AdjustmentSet(vignette: Vignette()))
        #expect(name(of: { $0.global.vignette?.amount = -0.8 }, from: vignetted) == "Vignette Amount")
        #expect(name(of: { $0.global.vignette?.highlights = 0.5 }, from: vignetted) == "Vignette Highlights")
        #expect(name(of: { $0.global.vignette?.isEnabled = false }, from: vignetted) == "Turn Off Vignette")
        let monochrome = EditRecipe(adjustments: AdjustmentSet(monochrome: Monochrome()))
        #expect(name(of: { $0.global.monochrome?.green = 0.3 }, from: monochrome) == "Black & White Green")
        let graded = EditRecipe(adjustments: AdjustmentSet(lut: LUT(name: "Film")))
        #expect(name(of: { $0.global.lut?.intensity = 0.5 }, from: graded) == "LUT Intensity")
        #expect(name(of: { $0.global.lut?.name = "Dusk" }, from: graded) == "Apply LUT")
        #expect(name(of: { $0.global.lut?.name = nil }, from: graded) == "Remove LUT")
    }

    @Test func curvesAndMixerNameTheChannelOrColor() {
        #expect(name { $0.global.curves = Curves(red: ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])) } == "Red Curve")
        #expect(name { $0.global.hsl = HSL(values: [.aqua: HSLValue(saturation: 0.4)]) } == "Aqua Saturation")
        #expect(name { $0.global.hsl = HSL(values: [.red: HSLValue(hue: 0.2), .blue: HSLValue(hue: 0.1)]) } == "Color Mixer")
    }

    @Test func geometryChangesAreActions() {
        #expect(name { $0.geometry = Geometry(quarterTurns: 1) } == "Rotate Right")
        #expect(name { $0.geometry = Geometry(quarterTurns: 3) } == "Rotate Left")
        #expect(name(of: { $0.geometry = Geometry(quarterTurns: 0) }, from: { var r = EditRecipe.identity; r.geometry = Geometry(quarterTurns: 3); return r }()) == "Rotate Right")
        #expect(name { $0.geometry = Geometry(isFlippedHorizontally: true) } == "Flip Horizontal")
        #expect(name { $0.geometry = Geometry(angle: 3) } == "Straighten")
        #expect(name { $0.geometry = Geometry(crop: UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)) } == "Crop")
        #expect(name { $0.geometry = Geometry(crop: UnitRect(x: 0.1, y: 0, width: 0.8, height: 1), aspectRatio: 1) } == "Aspect Ratio")
        #expect(name { $0.geometry = Geometry(angle: 3, quarterTurns: 1) } == "Crop & Straighten")
        // An identity geometry is no geometry: storing one or the other changes nothing visible.
        #expect(name { $0.geometry = Geometry() } == EditActionName.several)
    }

    @Test func masksAreNamedByWhatHappenedToThem() {
        let sky = AdjustmentLayer(mask: Mask(.sky))
        #expect(name { $0.layers.append(sky) } == "Add Sky Mask")
        var masked = EditRecipe.identity
        masked.layers.append(sky)
        #expect(name(of: { $0.layers.removeLast() }, from: masked) == "Delete Mask")
        #expect(name(of: { $0.layers[1].isEnabled = false }, from: masked) == "Turn Off Mask")
        #expect(name(of: { $0.layers[1].mask?.isInverted = true }, from: masked) == "Invert Mask")
        #expect(name(of: { $0.layers[1].mask?.feather = 0.3 }, from: masked) == "Mask Feather")
        #expect(name(of: { $0.layers[1].mask?.name = "Clouds" }, from: masked) == "Rename Mask")
        #expect(name(of: { $0.layers[1].adjustments.exposure = -0.5 }, from: masked) == "Exposure")
        #expect(name(of: { $0.layers[1].mask?.components.append(MaskComponent(operation: .subtract, kind: .people)) }, from: masked)
            == "Subtract People from Mask")
        #expect(name(of: { $0.layers[1].mask?.components[0].operation = .intersect }, from: masked) == "Intersect Mask with Sky")
        #expect(name(of: { $0.layers[1].mask?.components[0].kind = .linearGradient(LinearGradientMask()) }, from: masked) == "Linear Gradient")
    }

    @Test func brushStrokesAreNamedByWhatTheyDo() {
        var painted = EditRecipe.identity
        painted.layers.append(AdjustmentLayer(mask: Mask(.brush(BrushMask()))))
        let point = UnitPoint2D(x: 0.5, y: 0.5)
        func adding(_ stroke: BrushMask.Stroke) -> (inout EditRecipe) -> Void {
            { recipe in
                guard case var .brush(brush) = recipe.layers[1].mask?.components[0].kind else { return }
                brush.strokes.append(stroke)
                recipe.layers[1].mask?.components[0].kind = .brush(brush)
            }
        }
        #expect(name(of: adding(BrushMask.Stroke(points: [point], radius: 0.1)), from: painted) == "Brush Stroke")
        #expect(name(of: adding(BrushMask.Stroke(points: [point], radius: 0.1, erases: true)), from: painted) == "Erase")
    }

    @Test func retouchesAndCombinedChanges() {
        #expect(name { $0.retouches.append(Retouch(points: [UnitPoint2D(x: 0.5, y: 0.5)], radius: 0.02)) } == "Retouch")
        #expect(name { $0.global.exposure = 1; $0.global.contrast = 0.2 } == EditActionName.several)
        #expect(name { $0.global.exposure = 1; $0.geometry = Geometry(angle: 2) } == EditActionName.several)
    }
}
