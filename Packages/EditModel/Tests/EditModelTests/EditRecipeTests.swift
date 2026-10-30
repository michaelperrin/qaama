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
        #expect(AdjustmentSet.all.count == 12)
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
        recipe.layers.append(AdjustmentLayer(mask: MaskSpec(kind: .sky, isInverted: true), adjustments: AdjustmentSet(saturation: 0.4)))
        let data = try recipe.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\":2") && text.contains("\"layers\":["))
        #expect(text.contains("\"exposure\":1.25") && !text.contains("saturation\":0,"))
        #expect(text.contains("\"kind\":\"sky\""))

        let reloaded = try EditRecipe(jsonData: data)
        #expect(reloaded == recipe)
        #expect(reloaded.global.exposure == 1.25)
        #expect(reloaded.layers[1].mask?.kind == .sky)
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
