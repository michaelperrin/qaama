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
