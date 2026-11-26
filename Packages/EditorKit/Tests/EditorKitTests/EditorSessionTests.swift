import CoreImage
import EditModel
@testable import EditorKit
import Foundation
import ImageIO
import LibraryKit
import RenderEngine
import Testing
import UniformTypeIdentifiers

@MainActor
struct EditorSessionTests {
    @Test func showingAnotherPhotoClosesThePreviousOneAndKeepsTheCanvas() async throws {
        let source = SampleLibrarySource(count: 3)
        let ids = source.assets.map(\.id)
        let renderer = try #require(CanvasRenderer())
        let session = EditorSession(assetID: ids[0], source: source, renderer: renderer)
        let undoManager = UndoManager()
        session.undoManager = undoManager
        let first = session.model
        await first.open()
        #expect(first.isOpen)
        #expect(renderer.image != nil)

        session.show(ids[1])
        let second = session.model
        #expect(second.assetID == ids[1])
        #expect(second !== first)
        #expect(second.renderer === renderer)
        #expect(second.undoManager === undoManager)
        #expect(first.isClosed)
        #expect(first.renderer == nil)

        // The photo left behind can no longer draw on the canvas it used to own.
        await second.open()
        let shown = try #require(renderer.image)
        first.recipe.global.exposure = 1
        first.commitChange()
        #expect(renderer.image === shown)
        second.recipe.global.exposure = 0.5
        #expect(renderer.image !== shown)
    }

    @Test func aPhotoClosedBeforeItFinishedOpeningNeverDraws() async throws {
        let source = SampleLibrarySource(count: 2)
        let ids = source.assets.map(\.id)
        let renderer = try #require(CanvasRenderer())
        let session = EditorSession(assetID: ids[0], source: source, renderer: renderer)
        let first = session.model
        session.show(ids[1])
        await first.open()
        #expect(!first.isOpen)
        #expect(renderer.image == nil)
    }

    @Test func neighborsFollowTheLibraryOrderAndShowingTheSamePhotoIsANoOp() {
        let source = SampleLibrarySource(count: 3)
        let ids = source.assets.map(\.id)
        let session = EditorSession(assetID: ids[0], source: source, renderer: nil)
        #expect(session.neighbor(offset: -1) == nil)
        #expect(session.neighbor(offset: 1) == ids[1])
        let model = session.model
        session.show(ids[0])
        #expect(session.model === model)
        #expect(!model.isClosed)
        session.show(ids[2])
        #expect(session.neighbor(offset: 1) == nil)
        #expect(session.neighbor(offset: -1) == ids[1])
        session.close()
        #expect(session.model.isClosed)
    }

    // MARK: - Reading ahead

    private func makeImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).png")
        let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Lets the session's detached releases run.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func stayingOnAPhotoSettlesItAndReadsItsNeighborsAhead() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url, count: 4)
        let session = EditorSession(assetID: "stub-1", source: source, renderer: nil, settleDelay: .milliseconds(5))
        #expect(session.settledModel == nil)

        await session.followCurrentPhoto()
        #expect(session.model.isOpen)
        #expect(session.settledModel === session.model)
        // The photo itself, then the next one, then the previous one; nothing further away.
        #expect(source.inputRequests == ["stub-1", "stub-2", "stub"])

        // Stepping to a photo read ahead doesn't ask the source again.
        session.show("stub-2")
        await session.model.open()
        #expect(session.model.isOpen)
        #expect(source.inputRequests == ["stub-1", "stub-2", "stub"])
        #expect(session.settledModel?.assetID == "stub-1") // behind until the new photo settles

        // The photo just left is released: it may have been edited since it was read.
        await settle()
        #expect(source.endedIDs == ["stub-1"])
    }

    @Test func photosNoLongerNextToTheCurrentOneAreReleasedAndTheOneLeftIsReadAgain() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url, count: 4)
        let session = EditorSession(assetID: "stub-1", source: source, renderer: nil, settleDelay: .milliseconds(5))
        await session.followCurrentPhoto()
        session.show("stub-2")
        await session.followCurrentPhoto()
        await settle()
        // Now next to stub-2: stub-3 (new) and stub-1 (read again); stub is too far and released.
        #expect(source.inputRequests == ["stub-1", "stub-2", "stub", "stub-3", "stub-1"])
        #expect(Set(source.endedIDs) == ["stub-1", "stub"])
        #expect(source.endedIDs.count(where: { $0 == "stub-1" }) == 1)

        session.close()
        await settle()
        #expect(Set(source.endedIDs) == ["stub", "stub-1", "stub-2", "stub-3"])
        #expect(source.endedIDs.count(where: { $0 == "stub-2" }) == 1)
    }

    @Test func steppingBackwardReadsThePreviousPhotoFirst() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url, count: 5)
        let session = EditorSession(assetID: "stub-3", source: source, renderer: nil, settleDelay: .milliseconds(5))
        session.show("stub-2")
        await session.followCurrentPhoto()
        // stub-3 was left without having been read; then the photo further back, then the one behind.
        #expect(source.inputRequests.suffix(3) == ["stub-2", "stub-1", "stub-3"])
    }

    @Test func leavingBeforeAPhotoSettlesReadsNothingAhead() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url, count: 4)
        let session = EditorSession(assetID: "stub", source: source, renderer: nil, settleDelay: .milliseconds(200))
        let following = Task { await session.followCurrentPhoto() }
        try await Task.sleep(for: .milliseconds(30))
        session.show("stub-1")
        following.cancel()
        await following.value
        #expect(session.settledModel == nil)
        #expect(!source.inputRequests.contains("stub-2"))
    }

    @Test func theProxyIsShownUntilTheScreenOrTheRecipeAsksForThePhotosOwnPixels() async throws {
        let url = try makeImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = StubSource(imageURL: url)
        let renderer = try #require(CanvasRenderer())
        // The whole photo fits the view at a quarter of its size: its half, the proxy, is plenty.
        renderer.mtkView(renderer.makeView(), drawableSizeWillChange: CGSize(width: 1000, height: 1000))
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 2000)
        let full = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let proxy = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let photo = PreparedPhoto(keywords: ["sea"], input: EditingInput(imageURL: url), sourceImage: SourceImage(image: full, proxy: proxy, isRAW: true))
        let model = EditorModel(assetID: "stub", source: source, renderer: renderer, preparation: Task { photo })

        // Which of the two the canvas was given: the blue proxy or the red photo.
        func shown() throws -> String {
            let image = try #require(renderer.image)
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                                                                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel[2] > 250 ? "proxy" : pixel[0] > 250 ? "full" : "neither"
        }

        await model.open()
        #expect(model.isOpen && model.showsProxy)
        #expect(model.keywords == ["sea"])
        #expect(model.sourceImage?.pixelSize == extent.size)
        #expect(try shown() == "proxy")
        #expect(renderer.imageScale == 0.5 && renderer.actualSizeZoom == 4)

        // Until the user stays on the photo, the proxy whatever is asked.
        model.viewportSettleDelay = .milliseconds(5)
        renderer.setZoom(4)
        await settle()
        #expect(model.showsProxy)
        renderer.setZoom(1)

        // Staying on the photo changes nothing while the proxy serves; its pixels are decoded.
        model.settle()
        await settle()
        #expect(try model.showsProxy && shown() == "proxy")
        #expect(model.sourceImage?.holdsProxyPixels == true)

        // Zoomed in beyond what the proxy holds: the photo's own pixels, once the zoom has stopped.
        renderer.setZoom(3)
        renderer.setZoom(4)
        #expect(model.showsProxy)
        await settle()
        #expect(try !model.showsProxy && shown() == "full")
        #expect(renderer.imageScale == 1 && renderer.actualSizeZoom == 4)

        // Further in, the photo's pixels stay: there are no more of them on screen than the screen has.
        renderer.setZoom(6)
        #expect(!model.showsProxy)
        await settle()
        #expect(!model.showsProxy)

        // The proxy again as soon as the zoom moves below actual size, and for good where it serves.
        renderer.setZoom(3)
        #expect(try model.showsProxy && shown() == "proxy")
        renderer.setZoom(1)
        await settle()
        #expect(model.showsProxy)

        // Zoom 2 shows the proxy pixel for pixel: a little beyond is not worth the full resolution.
        renderer.setZoom(2.1)
        await settle()
        #expect(model.showsProxy)
        renderer.setZoom(2.3)
        await settle()
        #expect(!model.showsProxy)
        renderer.setZoom(1)
        await settle()
        #expect(model.showsProxy)

        // Noise reduction belongs to the decoding of the photo: the proxy doesn't carry it.
        model.recipe.global.denoise = Denoise(luminance: 0.5)
        #expect(!model.showsProxy && renderer.imageScale == 1)
        model.recipe.global.denoise = nil
        #expect(model.showsProxy)

        // Prepared by someone else: releasing the editing input is theirs to do.
        model.close()
        #expect(source.inputRequests.isEmpty && source.endedIDs.isEmpty)
    }
}
