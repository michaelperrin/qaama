import CoreImage
import EditModel
@testable import EditorKit
import Foundation
import RenderEngine
import Testing

@MainActor
struct ExportModelTests {
    private func makeDefaults() -> (UserDefaults, () -> Void) {
        let name = "ExportModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private var item: ExportItem {
        let image = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        var recipe = EditRecipe()
        recipe.geometry = Geometry(crop: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let input = ExportInput(image: image, recipe: recipe)
        return ExportItem(id: "a", baseName: "DSCF0001") { input }
    }

    @Test func settingsAreRememberedBetweenWindows() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let first = ExportModel(items: [item], defaults: defaults)
        #expect(first.settings == ExportSettings())
        first.settings = ExportSettings(format: .png, quality: 0.5, size: .width(1200))
        let second = ExportModel(items: [item], defaults: defaults)
        #expect(second.settings == ExportSettings(format: .png, quality: 0.5, size: .width(1200)))
        #expect(second.defaultFileName == "DSCF0001")
    }

    @Test func previewFollowsTheCropAndSizesReportTheOutput() async {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let model = ExportModel(items: [item], defaults: defaults)
        await model.loadPreview()
        #expect(model.errorMessage == nil)
        #expect(model.sourcePixelSize == CGSize(width: 200, height: 200))
        #expect(model.preview?.width == 200)
        model.settings.size = .longEdge(100)
        #expect(model.outputPixelSize == CGSize(width: 100, height: 100))
        #expect(!model.isUpscaling)
        model.settings.size = .height(400)
        #expect(model.isUpscaling)
    }

    @Test func encodingHonorsTheFormat() async {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let model = ExportModel(items: [item], defaults: defaults)
        model.settings = ExportSettings(format: .png, size: .longEdge(50))
        let data = await model.encodeFirst()
        #expect(model.errorMessage == nil)
        // PNG signature
        #expect(data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
