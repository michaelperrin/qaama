import CoreGraphics
import EditModel
@testable import EditorKit
import Foundation
import ImageIO
import LibraryKit
import Testing
import UniformTypeIdentifiers

/// A library source with one photo on disk, recording what the editor asks of it.
@Observable
final class StubSource: LibrarySource {
    let displayName = "Stub"
    var assets: AssetCollection
    let lastLoadDuration: Duration? = nil
    let capabilities: Set<LibraryCapability> = [.rating, .flag, .keywords]
    let queryCapabilities: Set<QueryCapability> = []
    var query = LibraryQuery.default
    let imageURL: URL
    var recipeData: Data?
    var savedOutputs: [EditingOutput] = []
    var ratings: [Int] = []
    var endedEditing = false

    init(imageURL: URL, recipeData: Data? = nil) {
        self.imageURL = imageURL
        self.recipeData = recipeData
        assets = AssetCollection([LibraryAsset(id: "stub", pixelWidth: 32, pixelHeight: 16, creationDate: nil, isFavorite: false)])
    }

    func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        assets.first { $0.id == id }
    }

    func load() async {}
    func thumbnail(for _: LibraryAsset, pixelSize _: CGSize) async -> CGImage? {
        nil
    }

    func fullSizeImage(for _: LibraryAsset) async -> CGImage? {
        nil
    }

    func setRating(_ rating: Int, for _: LibraryAsset) async throws {
        ratings.append(rating)
    }

    func setFlag(_: ItemFlag, for _: LibraryAsset) async throws {}
    func setKeywords(_: [String], for _: LibraryAsset) async throws {}

    func editingInput(for _: LibraryAsset) async throws -> EditingInput {
        EditingInput(imageURL: imageURL, recipeData: recipeData)
    }

    func saveEdit(_ output: EditingOutput, for _: LibraryAsset) async throws {
        savedOutputs.append(output)
    }

    func endEditing(_: LibraryAsset) {
        endedEditing = true
    }
}

@MainActor
struct EditorModelTests {
    private func makeImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString).png")
        let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func opensTheOriginalAndTheSavedRecipe() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = EditRecipe(exposure: 0.5)
        let source = try StubSource(imageURL: url, recipeData: saved.jsonData())
        let model = EditorModel(assetID: "stub", source: source, renderer: nil)

        await model.open()
        #expect(model.isOpen && model.sourceImage?.pixelSize == CGSize(width: 32, height: 16))
        #expect(model.recipe == saved && model.savedRecipe == saved && !model.hasUnsavedChanges)
        #expect(model.baseName.hasPrefix("editor-"))
        #expect(model.statusMessage == nil)

        model.close()
        #expect(source.endedEditing)
    }

    @Test func savesRenderedEditsAndResets() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url)
        let model = EditorModel(assetID: "stub", source: source, renderer: nil)
        await model.open()

        model.recipe.global.exposure = 1
        #expect(model.hasUnsavedChanges && model.canSave)
        await model.save()
        #expect(!model.hasUnsavedChanges)
        let output = try #require(source.savedOutputs.last)
        #expect(!output.isReset && !output.renderedJPEG.isEmpty)
        #expect(try EditRecipe(jsonData: output.recipeData).global.exposure == 1)

        model.reset()
        await model.save()
        #expect(source.savedOutputs.last?.isReset == true)
    }

    @Test func undoAndRedoFollowCommittedGestures() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(assetID: "stub", source: StubSource(imageURL: url), renderer: nil)
        await model.open()
        #expect(!model.canUndo)

        // A slider drags through several values, then the gesture ends: one undo step.
        model.recipe.global.exposure = 0.3
        model.recipe.global.exposure = 0.6
        model.commitChange()
        model.recipe.global.contrast = 0.2
        model.commitChange()
        #expect(model.undoStack.count == 2)

        model.undo()
        #expect(model.recipe.global.contrast == nil && model.recipe.global.exposure == 0.6)
        model.undo()
        #expect(model.recipe.isIdentity && !model.canUndo && model.canRedo)
        model.redo()
        #expect(model.recipe.global.exposure == 0.6)

        // A new change after an undo drops the redo history.
        model.recipe.global.saturation = -0.5
        model.commitChange()
        #expect(!model.canRedo)
    }

    @Test func undoManagerDrivesTheSameHistory() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(assetID: "stub", source: StubSource(imageURL: url), renderer: nil)
        let manager = UndoManager()
        manager.groupsByEvent = false
        model.undoManager = manager
        await model.open()

        manager.beginUndoGrouping()
        model.recipe.global.exposure = 1
        model.commitChange()
        manager.endUndoGrouping()
        #expect(manager.canUndo && manager.undoActionName == "Adjustment")

        manager.undo()
        #expect(model.recipe.isIdentity && manager.canRedo && !model.canUndo)
        manager.redo()
        #expect(model.recipe.global.exposure == 1 && manager.canUndo)

        model.close()
        #expect(!manager.canUndo)
    }

    @Test func readsMetadataAndComputesAHistogram() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(assetID: "stub", source: StubSource(imageURL: url), renderer: nil)
        await model.open()
        #expect(model.metadata?.pixelWidth == 32 && model.metadata?.pixelHeight == 16)
        for _ in 0 ..< 100 where model.histogram == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let histogram = try #require(model.histogram)
        #expect(histogram.luminance.max() == 1)
    }

    @Test func cropModeKeepsGeometryUntilItIsIdentity() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(assetID: "stub", source: StubSource(imageURL: url), renderer: nil)
        await model.open()

        model.beginCropping()
        #expect(model.isCropping && model.recipe.geometry == nil)
        model.geometry.crop = UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        model.geometry.angle = 3
        model.endCropping()
        #expect(!model.isCropping && model.recipe.geometry?.angle == 3 && model.canUndo)

        model.rotate(quarterTurns: -1)
        #expect(model.geometry.quarterTurns == 3)
        model.resetGeometry()
        #expect(model.recipe.geometry == nil)

        // Entering and leaving without touching anything leaves no trace.
        model.beginCropping()
        model.endCropping()
        #expect(model.recipe.geometry == nil)
    }

    @Test func unsupportedRecipeOpensTheOriginal() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url, recipeData: Data(#"{"version":1,"exposure":1}"#.utf8))
        let model = EditorModel(assetID: "stub", source: source, renderer: nil)
        await model.open()
        #expect(model.isOpen && model.recipe.isIdentity)
        #expect(model.statusMessage?.contains("unsupported") == true)
    }

    @Test func ratingIsUndoableThroughTheManager() async throws {
        let source = SampleLibrarySource(count: 1)
        let model = EditorModel(assetID: "sample-0", source: source, renderer: nil)
        let manager = UndoManager()
        manager.groupsByEvent = false
        model.undoManager = manager
        let original = try #require(source.asset(id: "sample-0")?.rating)

        manager.beginUndoGrouping()
        await model.setRating(original == 5 ? 1 : 5)
        manager.endUndoGrouping()
        #expect(source.asset(id: "sample-0")?.rating != original)
        #expect(manager.canUndo && manager.undoActionName == "Rating")

        manager.undo()
        for _ in 0 ..< 100 where source.asset(id: "sample-0")?.rating != original {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(source.asset(id: "sample-0")?.rating == original)
    }

    @Test func decisionsGoThroughTheSource() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url)
        let model = EditorModel(assetID: "stub", source: source, renderer: nil)
        await model.setRating(4)
        #expect(source.ratings == [4])
        await model.setKeywords(["a"])
        #expect(model.keywords == ["a"] && model.statusMessage == nil)
    }
}

@MainActor
struct PresetStoreTests {
    @Test func savesListsAppliesAndDeletesPresets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PresetStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directory: directory)
        #expect(store.presets.isEmpty)

        try store.save(AdjustmentSet(exposure: 0.7, saturation: -0.2), named: " Moody / Dusk ")
        try store.save(AdjustmentSet(contrast: 0.3), named: "Punch")
        #expect(store.presets.map(\.name) == ["Moody - Dusk", "Punch"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains("Moody - Dusk.json"))

        let reopened = PresetStore(directory: directory)
        #expect(reopened.presets.first?.adjustments.exposure == 0.7)

        let model = EditorModel(assetID: "stub", source: SampleLibrarySource(count: 1), renderer: nil)
        try model.apply(#require(store.presets.first))
        #expect(model.recipe.global.exposure == 0.7 && model.canUndo)

        try store.delete(store.presets[1])
        #expect(store.presets.count == 1)
        #expect(throws: PresetStore.PresetError.self) { try store.save(AdjustmentSet(), named: "   ") }
    }

    @Test func clipboardCopiesAdjustmentsBetweenEditors() {
        let clipboard = AdjustmentsClipboard()
        let source = SampleLibrarySource(count: 2)
        let first = EditorModel(assetID: "sample-0", source: source, renderer: nil)
        first.recipe.global.vibrance = 0.5
        first.geometry.angle = 5
        first.copyAdjustments(to: clipboard)

        let second = EditorModel(assetID: "sample-1", source: source, renderer: nil)
        second.geometry.crop = UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        second.pasteAdjustments(from: clipboard)
        #expect(second.recipe.global.vibrance == 0.5)
        #expect(second.geometry.crop.width == 0.5 && second.geometry.angle == 0, "pasting keeps the photo's own crop")
    }
}

@MainActor
struct BatchEditingTests {
    @Test func copiesAndPastesSavedAdjustmentsFromTheGrid() async throws {
        let source = SampleLibrarySource(count: 3)
        let clipboard = AdjustmentsClipboard()
        let edited = source.assets[0], target = source.assets[1]
        let recipe = EditRecipe(adjustments: AdjustmentSet(exposure: 0.8))
        let output = try EditingOutput(recipeData: recipe.jsonData(), renderedJPEG: Data())
        try await source.saveEdit(output, for: edited)

        try await BatchEditing.copyAdjustments(of: edited, from: source, to: clipboard)
        #expect(clipboard.adjustments?.exposure == 0.8)
        await #expect(throws: BatchEditing.BatchError.self) {
            try await BatchEditing.copyAdjustments(of: source.assets[2], from: source, to: clipboard)
        }

        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        let count = try await BatchEditing.pasteAdjustments(to: [target], in: source, from: clipboard, undoManager: manager)
        manager.endUndoGrouping()
        #expect(count == 1)
        let saved = try await source.editingInput(for: target).recipeData
        #expect(try EditRecipe(jsonData: #require(saved)).global.exposure == 0.8)
        #expect(source.asset(id: target.id)?.hasEdit == true)
        #expect(manager.canUndo && manager.undoActionName == "Paste Adjustments")

        // Undo restores the photo to untouched; redo pastes again.
        manager.undo()
        for _ in 0 ..< 100 where source.asset(id: target.id)?.hasEdit == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(source.asset(id: target.id)?.hasEdit == false)
        for _ in 0 ..< 100 where !manager.canRedo {
            try await Task.sleep(for: .milliseconds(10))
        }
        manager.redo()
        for _ in 0 ..< 100 where source.asset(id: target.id)?.hasEdit != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(source.asset(id: target.id)?.hasEdit == true)
    }
}
