@testable import EditModel
import Foundation
import Testing

struct EditRecipeTests {
    @Test func defaultRecipeIsIdentity() {
        #expect(EditRecipe().isIdentity)
        #expect(!EditRecipe(exposure: 0.5).isIdentity)
    }

    @Test func clampsValuesToTheirRanges() {
        let recipe = EditRecipe(exposure: 10, contrast: -5, saturation: 2)
        #expect(recipe.exposure == 3)
        #expect(recipe.contrast == -1)
        #expect(recipe.saturation == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        let recipe = EditRecipe(exposure: 1.25, contrast: -0.3, saturation: 0.4)
        let data = try recipe.jsonData()
        #expect(try EditRecipe(jsonData: data) == recipe)
        #expect(String(decoding: data, as: UTF8.self).contains("\"exposure\":1.25"))
    }

    @Test func rejectsNewerVersions() throws {
        let json = Data(#"{"version":99,"exposure":0,"contrast":0,"saturation":0}"#.utf8)
        #expect(throws: EditRecipe.DecodingError.unsupportedVersion(99)) {
            try EditRecipe(jsonData: json)
        }
    }
}
