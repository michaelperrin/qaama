import CoreGraphics
import EditModel
@testable import EditorKit
import Foundation
import ImageIO
import RenderEngine
import Testing
import UniformTypeIdentifiers

@MainActor
struct EditorLUTTests {
    /// A gray photo, a library of its own, and `.cube` files to import into it.
    @MainActor private struct Fixture {
        let root: URL
        let imageURL: URL
        let library: LUTLibrary

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("lut-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = LUTLibrary(directory: root.appendingPathComponent("library"))
            imageURL = root.appendingPathComponent("photo.png")
            let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            let destination = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// The smallest table: every color becomes `color`.
        func writeCube(named name: String, color: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(("LUT_3D_SIZE 2\n" + Array(repeating: color, count: 8).joined(separator: "\n")).utf8).write(to: url)
            return url
        }

        func openModel() async -> EditorModel {
            let model = EditorModel(assetID: "stub", source: StubSource(imageURL: imageURL), renderer: nil, luts: library)
            await model.open()
            return model
        }
    }

    /// The histogram of what the canvas shows, once it has settled; where its tones pile up.
    private func brightestBin(of model: EditorModel) async throws -> Int {
        try await Task.sleep(for: .milliseconds(300))
        let luminance = try #require(model.histogram).luminance
        return try #require(luminance.indices.max { luminance[$0] < luminance[$1] })
    }

    @Test func storeImportsReportsFailuresAndDeletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = LUTStore(library: fixture.library)
        #expect(store.names.isEmpty)
        let notATable = fixture.root.appendingPathComponent("Notes.cube")
        try Data("hello".utf8).write(to: notATable)
        let report = try await store.importFiles(at: [
            fixture.writeCube(named: "Black.cube", color: "0 0 0"), notATable, fixture.writeCube(named: "White.cube", color: "1 1 1"),
        ])
        #expect(report.imported == ["Black", "White"])
        #expect(report.failures.count == 1 && report.failures[0].hasPrefix("“Notes.cube” can't be used as a LUT"))
        #expect(store.names == ["Black", "White"])
        try store.delete("Black")
        #expect(store.names == ["White"])
    }

    @Test func tryingATableShowsItWithoutTouchingTheRecipe() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Black.cube", color: "0 0 0"))
        let model = await fixture.openModel()
        let original = try await brightestBin(of: model)
        #expect(original > 100)

        model.previewLUT(.table("Black"))
        #expect(model.recipe.isIdentity && !model.canUndo && !model.hasUnsavedChanges)
        #expect(try await brightestBin(of: model) == 0, "the canvas shows the table being tried")

        model.previewLUT(nil)
        #expect(try await brightestBin(of: model) == original)
    }

    @Test func choosingATableIsOneUndoableStep() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Black.cube", color: "0 0 0"))
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "White.cube", color: "1 1 1"))
        let model = await fixture.openModel()
        let original = try await brightestBin(of: model)

        model.previewLUT(.table("White"))
        model.chooseLUT(.table("Black"))
        #expect(model.adjustments.lut == LUT(name: "Black"))
        #expect(model.undoStack.count == 1)
        #expect(try await brightestBin(of: model) == 0, "the choice replaces what was being tried")

        // Another table keeps the intensity and switches a LUT that was off back on.
        model.adjustments.lut?.intensity = 0.4
        model.adjustments.lut?.isEnabled = false
        model.commitChange()
        model.chooseLUT(.table("White"))
        #expect(model.adjustments.lut == LUT(name: "White", intensity: 0.4))

        // No table: the setting stays, for the next table.
        model.chooseLUT(.none)
        #expect(model.adjustments.lut == LUT(name: nil, intensity: 0.4))
        #expect(model.recipe.isIdentity)
        #expect(try await brightestBin(of: model) == original)

        model.undo()
        #expect(model.adjustments.lut?.name == "White")
        let steps = model.undoStack.count
        model.chooseLUT(.table("White"))
        #expect(model.undoStack.count == steps, "choosing the table already there is no change")
    }

    @Test func tryingNoTableShowsThePhotoWithoutItsOwn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Black.cube", color: "0 0 0"))
        let model = await fixture.openModel()
        let original = try await brightestBin(of: model)
        model.chooseLUT(.table("Black"))
        model.previewLUT(EditorModel.LUTChoice.none)
        #expect(try await brightestBin(of: model) == original)
        // Leaving the menu on the choice already made: the preview goes, the table stays.
        model.chooseLUT(.table("Black"))
        #expect(try await brightestBin(of: model) == 0)
    }

    @Test func aTableCanBeGivenToAMaskedLayer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = await fixture.openModel()
        model.addMaskLayer(.linearGradient(LinearGradientMask()))
        model.chooseLUT(.table("Film"))
        #expect(model.recipe.global.lut == nil)
        #expect(model.recipe.layers[1].adjustments.lut?.name == "Film")
    }
}
