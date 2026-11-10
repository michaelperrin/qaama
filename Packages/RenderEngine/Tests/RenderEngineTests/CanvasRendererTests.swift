import CoreImage
import EditModel
import Metal
@testable import RenderEngine
import Testing

@MainActor
struct CanvasRendererTests {
    /// Renders a solid red image into an offscreen texture and reads the center pixel back.
    @Test func drawsTheImageIntoTheTexture() throws {
        let renderer = try #require(CanvasRenderer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let queue = try #require(renderer.device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())

        // 2:1 image fitted in a square texture: fills the middle band, leaves the top and bottom black.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 16))
        #expect(renderer.render(red, into: texture, commandBuffer: commandBuffer, pointScale: 1))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixel = [Float16](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 64 * 8, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        #expect(pixel[0] > 0.5, "red channel at the center should be lit, got \(pixel)")
        #expect(pixel[1] < 0.1 && pixel[2] < 0.1)

        var corner = [Float16](repeating: 0, count: 4)
        texture.getBytes(&corner, bytesPerRow: 64 * 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        #expect(corner[0] < 0.05, "corner outside the image should stay black, got \(corner)")
    }
}

@MainActor
struct CanvasRendererFileTests {
    /// Same as above, but the image comes from a JPEG on disk through the real loader and pipeline,
    /// so lazy decoding is exercised too.
    @Test func drawsAJPEGFileIntoTheTexture() throws {
        let renderer = try #require(CanvasRenderer())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        try CIContext().writeJPEGRepresentation(of: green, to: url, colorSpace: #require(CGColorSpace(name: CGColorSpace.sRGB)))

        let loaded = try SourceImageLoader.load(.file(url))
        let filtered = RenderPipeline.apply(EditRecipe(exposure: 0.1), to: loaded.image)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let queue = try #require(renderer.device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        #expect(renderer.render(filtered, into: texture, commandBuffer: commandBuffer, pointScale: 1))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixel = [Float16](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 64 * 8, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        #expect(pixel[1] > 0.5, "green channel at the center should be lit, got \(pixel)")
    }
}

@MainActor
struct SourceImageDraftTests {
    @Test func aDraftIsStretchedToCoverTheFullImageExactly() {
        let draft = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 25))
        let full = CGRect(x: 0, y: 0, width: 101, height: 50)
        let stretched = SourceImageLoader.stretched(draft, to: full)
        #expect(stretched.extent == full)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(stretched, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 100, y: 49, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(pixel[2] > 250 && pixel[3] == 255) // blue up to the far corner
    }

    @Test func aPlainImageHasNoDraft() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        try CIContext().writeJPEGRepresentation(of: green, to: url, colorSpace: #require(CGColorSpace(name: CGColorSpace.sRGB)))
        let loaded = try SourceImageLoader.load(.file(url))
        #expect(loaded.draftPixels == nil && loaded.draft == nil && !loaded.isRAW)
        let pixels = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(loaded.withDraftPixels(pixels).draft?.extent == loaded.image.extent)
    }

    @Test func rasterizingKeepsTheExtentAndTheValuesIncludingAboveOne() async throws {
        let renderer = try #require(CanvasRenderer())
        let extent = CGRect(x: 10, y: 20, width: 64, height: 32)
        // Left half brighter than white, right half dark: what a RAW's highlights look like.
        let bright = CIImage(color: CIColor(red: 1, green: 0.5, blue: 0.25)).cropped(to: CGRect(x: 10, y: 20, width: 32, height: 32))
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.5])
        let dark = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.3)).cropped(to: extent)
        let image = bright.composited(over: dark)
        let raster = try #require(await renderer.rasterized(image))
        #expect(raster.extent == extent)

        let context = CIContext()
        func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> [Float] {
            var p = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return p
        }
        for point in [(20.0, 30.0), (60.0, 40.0)] {
            let expected = pixel(image, x: point.0, y: point.1), got = pixel(raster, x: point.0, y: point.1)
            for channel in 0 ..< 3 {
                #expect(abs(expected[channel] - got[channel]) < 0.01, "\(expected) vs \(got)")
            }
        }
        #expect(pixel(raster, x: 20, y: 30)[0] > 1.5) // not clipped to white
        #expect(await renderer.rasterized(CIImage(color: .red)) == nil) // an infinite image has no pixels to keep
    }
}

struct CanvasZoomTests {
    @Test func fitScaleIsTheTighterOfTheTwoAxes() {
        #expect(CanvasRenderer.fitScale(imageSize: CGSize(width: 6000, height: 4000), in: CGSize(width: 1500, height: 1500)) == 0.25)
        #expect(CanvasRenderer.fitScale(imageSize: CGSize(width: 400, height: 1000), in: CGSize(width: 1000, height: 500)) == 0.5)
        #expect(CanvasRenderer.fitScale(imageSize: .zero, in: CGSize(width: 1000, height: 500)) == 0)
        #expect(CanvasRenderer.fitScale(imageSize: CGSize(width: 10, height: 10), in: .zero) == 0)
    }

    @MainActor @Test func actualSizeZoomUndoesTheFit() throws {
        let renderer = try #require(CanvasRenderer())
        #expect(renderer.actualSizeZoom == nil)
        renderer.image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        // No view yet: the drawable size is unknown.
        #expect(renderer.actualSizeZoom == nil)
        let view = renderer.makeView()
        renderer.mtkView(view, drawableSizeWillChange: CGSize(width: 1500, height: 1500))
        #expect(renderer.actualSizeZoom == 4)
        renderer.setZoom(100)
        #expect(renderer.zoom == CanvasRenderer.maximumZoom)
    }

    @MainActor @Test func zoomStopsAtFitAndRecentersThere() throws {
        let renderer = try #require(CanvasRenderer())
        renderer.image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        renderer.mtkView(renderer.makeView(), drawableSizeWillChange: CGSize(width: 1500, height: 1500))
        #expect(renderer.zoomRange == 1 ... CanvasRenderer.maximumZoom)
        renderer.setZoom(3)
        renderer.panOffset = CGPoint(x: 40, y: -20)
        renderer.setZoom(2)
        #expect(renderer.panOffset == CGPoint(x: 40, y: -20)) // still zoomed in: the pan is kept
        renderer.setZoom(0.3)
        #expect(renderer.zoom == 1)
        #expect(renderer.panOffset == .zero)
    }

    @MainActor @Test func imageRectFollowsZoomAndPan() throws {
        let renderer = try #require(CanvasRenderer())
        #expect(renderer.imageRect(inViewOfSize: CGSize(width: 800, height: 600)) == nil)
        renderer.image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4000, height: 2000))
        // Fitted: the full width, centered vertically.
        #expect(renderer.imageRect(inViewOfSize: CGSize(width: 800, height: 600)) == CGRect(x: 0, y: 100, width: 800, height: 400))
        renderer.zoom = 2
        renderer.panOffset = CGPoint(x: 30, y: -10)
        #expect(renderer.imageRect(inViewOfSize: CGSize(width: 800, height: 600)) == CGRect(x: -370, y: -110, width: 1600, height: 800))
    }

    @MainActor @Test func aPhotoSmallerThanTheViewZoomsOutToItsActualSize() throws {
        let renderer = try #require(CanvasRenderer())
        renderer.image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        renderer.mtkView(renderer.makeView(), drawableSizeWillChange: CGSize(width: 1500, height: 1500))
        // Fit enlarges it five times, so 100% is below Fit and becomes the lower end.
        #expect(renderer.zoomRange.lowerBound == 0.2)
        renderer.setZoom(0.01)
        #expect(renderer.zoom == 0.2)
    }
}
