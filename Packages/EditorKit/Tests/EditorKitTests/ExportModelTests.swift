import CoreImage
import EditModel
@testable import EditorKit
import Foundation
import LibraryKit
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
        let input = ExportInput(image: image, recipe: recipe, baseName: "DSCF0001")
        return ExportItem(id: "a") { input }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func settingsAreRememberedBetweenWindows() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let first = ExportModel(items: [item], defaults: defaults)
        #expect(first.settings == ExportSettings())
        first.settings = ExportSettings(format: .png, quality: 0.5, size: .width(1200))
        let second = ExportModel(items: [item], defaults: defaults)
        #expect(second.settings == ExportSettings(format: .png, quality: 0.5, size: .width(1200)))
    }

    @Test func namesAvoidCollisionsIgnoringCase() {
        var taken: Set = ["dscf0001.jpg"]
        #expect(ExportModel.uniqueFileName(base: "DSCF0001", extension: "jpg", taken: &taken) == "DSCF0001 2.jpg")
        #expect(ExportModel.uniqueFileName(base: "DSCF0001", extension: "jpg", taken: &taken) == "DSCF0001 3.jpg")
        #expect(ExportModel.uniqueFileName(base: "DSCF0001", extension: "png", taken: &taken) == "DSCF0001.png")
    }

    @Test func batchWritesEveryPhotoAndReportsFailures() async throws {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("DSCF0001.jpg"))
        let broken = ExportItem(id: "broken") { throw LibrarySourceError.assetUnavailable }
        let model = ExportModel(items: [item, item, broken], defaults: defaults)
        model.settings = ExportSettings(format: .jpeg, size: .longEdge(40))
        let written = await model.exportAll(to: folder)
        #expect(written == 2)
        #expect(model.completedCount == 3)
        #expect(model.failures.count == 1 && model.failures.first?.name == "broken")
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["DSCF0001.jpg", "DSCF0001 2.jpg", "DSCF0001 3.jpg"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("DSCF0001.jpg")).isEmpty)
    }

    @Test func previewFollowsTheCropAndSizesReportTheOutput() async {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let model = ExportModel(items: [item], defaults: defaults)
        await model.loadPreview()
        #expect(model.errorMessage == nil)
        #expect(model.defaultFileName == "DSCF0001")
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
