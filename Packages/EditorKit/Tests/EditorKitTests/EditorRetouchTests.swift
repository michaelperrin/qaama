import CoreGraphics
import CoreImage
import EditModel
@testable import EditorKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor
struct EditorRetouchTests {
    /// A 160 × 120 blue gradient with a red square at (40…59, 30…49) from the top-left.
    private func makeImage() throws -> URL {
        let width = 160, height = 120
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let i = (row * width + column) * 4
                if (40 ..< 60).contains(column), (30 ..< 50).contains(row) {
                    bytes[i] = 230; bytes[i + 1] = 20; bytes[i + 2] = 20
                } else {
                    bytes[i] = UInt8(60 + row); bytes[i + 1] = UInt8(100 + row); bytes[i + 2] = 235
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retouch-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func openModel(at url: URL) async -> (EditorModel, StubSource) {
        let source = StubSource(imageURL: url)
        let model = EditorModel(assetID: "stub", source: source, renderer: nil)
        await model.open()
        return (model, source)
    }

    /// Paints one dab over the red square.
    private func paintOverTheSquare(_ model: EditorModel) {
        model.beginRetouchStroke(at: UnitPoint2D(x: 50.0 / 160, y: 40.0 / 120))
        model.extendRetouchStroke(to: UnitPoint2D(x: 51.0 / 160, y: 40.0 / 120))
        model.endRetouchStroke()
    }

    private func waitForFills(of model: EditorModel) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !model.pendingRetouches.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The color of the JPEG's pixel at (`x`, `y`) from the top-left.
    private func color(in jpeg: Data, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test func aStrokeBecomesOneUndoableRetouchAndItsFillFollows() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let (model, _) = await openModel(at: url)
        let undoManager = UndoManager()
        model.undoManager = undoManager

        // Without the tool, the canvas doesn't paint.
        model.beginRetouchStroke(at: UnitPoint2D(x: 0.3, y: 0.3))
        #expect(model.retouchStroke == nil)

        model.beginRetouching(radius: 16.0 / 160)
        #expect(model.isRetouching)
        model.beginRetouchStroke(at: UnitPoint2D(x: 50.0 / 160, y: 40.0 / 120))
        #expect(model.retouchStroke?.points.count == 1 && model.recipe.retouches.isEmpty, "the stroke stays out of the recipe while it is painted")
        model.extendRetouchStroke(to: UnitPoint2D(x: 51.0 / 160, y: 40.0 / 120))
        model.endRetouchStroke()
        #expect(model.retouchStroke == nil && model.recipe.retouches.count == 1 && model.recipe.retouches[0].points.count == 2)
        #expect(model.canUndo && undoManager.undoActionName == "Retouch")
        #expect(model.pendingRetouches.count == 1)

        await waitForFills(of: model)
        let retouch = model.recipe.retouches[0]
        let fill = try #require(model.retouchFills[retouch.id])
        #expect(!fill.extent.isEmpty && model.statusMessage == nil)

        // The saved render no longer shows the square, where it was and nowhere else.
        let jpeg = try await model.renderJPEG()
        let healed = try color(in: jpeg, x: 50, y: 40), elsewhere = try color(in: jpeg, x: 120, y: 40)
        #expect(healed.r < 150 && healed.b > 200)
        #expect(abs(healed.r - elsewhere.r) < 30)

        // Undo removes the retouch but keeps its fill, so the redo has nothing to compute.
        undoManager.undo()
        #expect(model.recipe.retouches.isEmpty && model.retouchFills[retouch.id] === fill)
        undoManager.redo()
        #expect(model.recipe.retouches == [retouch] && model.pendingRetouches.isEmpty && model.retouchFills[retouch.id] === fill)

        model.removeRetouches()
        #expect(model.recipe.retouches.isEmpty && undoManager.undoActionName == "Remove Retouches")
        model.close()
    }

    @Test func fillsOfAListThatDivergedAreDropped() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let (model, _) = await openModel(at: url)
        model.beginRetouching(radius: 16.0 / 160)
        paintOverTheSquare(model)
        model.beginRetouchStroke(at: UnitPoint2D(x: 0.7, y: 0.6))
        model.endRetouchStroke()
        await waitForFills(of: model)
        let first = model.recipe.retouches[0], second = model.recipe.retouches[1]
        #expect(model.retouchFills.count == 2)

        // Undo the second, paint something else: the second's fill was for a list that is gone.
        model.undo()
        #expect(model.retouchFills[second.id] != nil)
        model.beginRetouchStroke(at: UnitPoint2D(x: 0.2, y: 0.8))
        model.endRetouchStroke()
        #expect(model.retouchFills[second.id] == nil && model.retouchFills[first.id] != nil)
        await waitForFills(of: model)
        #expect(model.retouchFills.count == 2 && model.retouchFills[model.recipe.retouches[1].id] != nil)
        model.close()
    }

    @Test func aSavedRetouchIsFilledWhenThePhotoOpens() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        var saved = EditRecipe()
        saved.retouches = [Retouch(points: [UnitPoint2D(x: 50.0 / 160, y: 40.0 / 120)], radius: 16.0 / 160)]
        let source = try StubSource(imageURL: url, recipeData: saved.jsonData())
        let model = EditorModel(assetID: "stub", source: source, renderer: nil)
        await model.open()
        #expect(model.recipe == saved && !model.hasUnsavedChanges)
        await waitForFills(of: model)
        #expect(model.retouchFills[saved.retouches[0].id]?.extent.isEmpty == false)
        model.close()
    }

    @Test func pointsMapThroughTheCropAndTheGeometry() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let (model, _) = await openModel(at: url)
        let point = UnitPoint2D(x: 0.25, y: 0.5)
        #expect(model.sourcePoint(fromDisplayed: point) == point)

        // Flipped and cropped to the right half: the displayed left edge is the original's middle.
        model.geometry = Geometry(isFlippedHorizontally: true, crop: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let source = model.sourcePoint(fromDisplayed: UnitPoint2D(x: 0, y: 0.5))
        #expect(abs(source.x - 0.5) < 1e-9 && source.y == 0.5)
        let back = model.displayedPoint(fromSource: source)
        #expect(abs(back.x) < 1e-9 && back.y == 0.5)

        model.geometry = Geometry(angle: 7, quarterTurns: 1)
        let there = model.sourcePoint(fromDisplayed: point), again = model.displayedPoint(fromSource: there)
        #expect(abs(again.x - point.x) < 1e-9 && abs(again.y - point.y) < 1e-9)
        model.close()
    }

    @Test func theToolGivesWayToTheCropTool() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let (model, _) = await openModel(at: url)
        model.beginCropping()
        model.beginRetouching()
        #expect(model.isRetouching && !model.isCropping)
        model.beginRetouchStroke(at: UnitPoint2D(x: 0.5, y: 0.5))
        model.beginCropping()
        #expect(!model.isRetouching && model.isCropping && model.retouchStroke == nil)
        #expect(EditorModel.RetouchTool(radius: 5).radius == Retouch.radiusRange.upperBound)
        model.close()
    }
}
