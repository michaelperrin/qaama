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
