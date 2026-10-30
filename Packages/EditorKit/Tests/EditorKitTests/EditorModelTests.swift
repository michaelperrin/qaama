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

    @Test func unsupportedRecipeOpensTheOriginal() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url, recipeData: Data(#"{"version":1,"exposure":1}"#.utf8))
        let model = EditorModel(assetID: "stub", source: source, renderer: nil)
        await model.open()
        #expect(model.isOpen && model.recipe.isIdentity)
        #expect(model.statusMessage?.contains("unsupported") == true)
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
