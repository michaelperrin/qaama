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
        makeItem(id: "a")
    }

    private func makeItem(id: String) -> ExportItem {
        let image = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        var recipe = EditRecipe()
        recipe.geometry = Geometry(crop: UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        let input = ExportInput(image: image, recipe: recipe)
        return ExportItem(id: id, name: { "DSCF0001" }, load: { input })
    }

    /// Stores in temporary folders, so tests never touch the real watermarks or presets.
    private let store = WatermarkStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ExportModelTests-\(UUID().uuidString)"))
    private let presetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ExportPresets-\(UUID().uuidString)")

    @Test func presetsSaveApplyAndDelete() throws {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        defer { try? FileManager.default.removeItem(at: presetDirectory) }
        let presets = ExportPresetStore(directory: presetDirectory)
        let model = ExportModel(items: [item], defaults: defaults, watermarks: store, presets: presets)
        #expect(model.currentPreset == nil)
        model.settings = ExportSettings(format: .png, size: .longEdge(2048), naming: .sequence(prefix: "Web-", start: 1, digits: 3))
        model.savePreset(named: "Web/Small")
        #expect(model.errorMessage == nil)
        #expect(model.currentPreset?.name == "Web-Small")
        model.settings.quality = 0.5
        #expect(model.currentPreset == nil)
        let saved = try #require(presets.presets.first)
        model.apply(saved)
        #expect(model.settings.format == .png && model.currentPreset == saved)
        #expect(ExportPresetStore(directory: presetDirectory).presets == [saved])
        model.deleteCurrentPreset()
        #expect(presets.presets.isEmpty && model.currentPreset == nil)
        model.savePreset(named: "  ")
        #expect(model.errorMessage != nil)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func settingsAreRememberedBetweenWindows() {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let first = ExportModel(items: [item], defaults: defaults, watermarks: store, presets: ExportPresetStore(directory: presetDirectory))
        #expect(first.settings == ExportSettings())
        first.settings = ExportSettings(format: .png, quality: 0.5, size: .width(1200))
        let second = ExportModel(items: [item], defaults: defaults, watermarks: store, presets: ExportPresetStore(directory: presetDirectory))
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
        let broken = ExportItem(id: "broken", name: { "broken" }, load: { throw LibrarySourceError.assetUnavailable })
        let model = ExportModel(items: [item, item, broken], defaults: defaults, watermarks: store, presets: ExportPresetStore(directory: presetDirectory))
        model.settings = ExportSettings(format: .jpeg, size: .longEdge(40))
        let written = await model.exportAll(to: folder)
        #expect(written == 2)
        #expect(model.completedCount == 3)
        #expect(model.failures.count == 1 && model.failures.first?.name == "broken")
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["DSCF0001.jpg", "DSCF0001 2.jpg", "DSCF0001 3.jpg"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("DSCF0001.jpg")).isEmpty)
    }

    @Test func batchCanOverwriteAndNumberTheFiles() async throws {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("Trip-01.png"))
        let model = ExportModel(items: [makeItem(id: "a"), makeItem(id: "b")], defaults: defaults, watermarks: store, presets: ExportPresetStore(directory: presetDirectory))
        model.settings = ExportSettings(format: .png, size: .longEdge(20), naming: .sequence(prefix: "Trip-", start: 1, digits: 2), existingFiles: .overwrite)
        #expect(model.outputFileName(for: model.items[1]) == nil) // name not resolved yet
        _ = await model.name(for: model.items[1])
        #expect(model.outputFileName(for: model.items[1]) == "Trip-02.png")
        let written = await model.exportAll(to: folder)
        #expect(written == 2)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["Trip-01.png", "Trip-02.png"])
        #expect(try !Data(contentsOf: folder.appendingPathComponent("Trip-01.png")).isEmpty)
    }

    @Test func previewFollowsTheCropAndSizesReportTheOutput() async {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let model = ExportModel(items: [item], defaults: defaults, watermarks: store, presets: ExportPresetStore(directory: presetDirectory))
        await model.loadPreview()
        #expect(model.errorMessage == nil)
        #expect(model.defaultFileName == "DSCF0001")
        #expect(model.sourcePixelSize == CGSize(width: 200, height: 200))
        #expect(model.preview?.width == 200)
        #expect(model.outputFileName(for: model.items[0]) == "DSCF0001.jpg")
        model.settings.frame = ExportFrame(isEnabled: true, thickness: 0.1)
        #expect(model.sourcePixelSize == CGSize(width: 240, height: 240))
        await model.loadPreview()
        #expect(model.preview?.width == 240)
        model.settings.frame = ExportFrame()
        model.settings.size = .longEdge(100)
        #expect(model.outputPixelSize == CGSize(width: 100, height: 100))
        #expect(!model.isUpscaling)
        model.settings.size = .height(400)
        #expect(model.isUpscaling)
    }

    @Test func encodingHonorsTheFormat() async {
        let (defaults, cleanup) = makeDefaults()
        defer { cleanup() }
        let model = ExportModel(items: [item], defaults: defaults, watermarks: store, presets: ExportPresetStore(directory: presetDirectory))
        model.settings = ExportSettings(format: .png, size: .longEdge(50))
        let data = await model.encodeSelected()
        #expect(model.errorMessage == nil)
        // PNG signature
        #expect(data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
