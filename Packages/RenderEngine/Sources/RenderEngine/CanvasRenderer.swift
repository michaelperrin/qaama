import CoreImage
import Foundation
import Metal
import MetalKit
import Observation
import OSLog

/// Draws a `CIImage` into an `MTKView` through Core Image's Metal backend.
///
/// The view is paused and redraws only when `setNeedsDisplay` is called, i.e. when the image or
/// the viewport changes. Platform-neutral: MetalKit exists on macOS and iOS alike.
///
/// Known limitation: the Metal layer shows nothing inside a SwiftUI sheet on macOS 27 (the sheet
/// composites its content off screen), so the canvas must live in a regular window or column.
@Observable
public final class CanvasRenderer: NSObject, MTKViewDelegate {
    /// Image to display, already filtered. Setting it schedules a redraw.
    public var image: CIImage? {
        didSet { view?.setNeedsDisplay(view?.bounds ?? .zero) }
    }

    /// 1 = fit the whole image in the view. Setting it schedules a redraw.
    public var zoom: CGFloat = 1 {
        didSet { view?.setNeedsDisplay(view?.bounds ?? .zero) }
    }

    /// Offset of the image center from the view center, in view points.
    public var panOffset: CGPoint = .zero {
        didSet { view?.setNeedsDisplay(view?.bounds ?? .zero) }
    }

    /// GPU time of the last frame, for the latency measurements of the proof of concept.
    public private(set) var lastRenderDuration: Duration?

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private weak var view: MTKView?
    // Plain sRGB for the proof of concept; extended-range output (rgba16Float + linear P3) comes later.
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "CanvasRenderer")

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        commandQueue = queue
        context = CIContext(mtlCommandQueue: queue, options: [
            .cacheIntermediates: true,
            .name: "Qaama canvas",
        ])
        super.init()
    }

    /// Creates the Metal view this renderer draws into. Call once.
    public func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = self
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.view = view
        return view
    }

    /// Shared Core Image context, for exports that must match what the canvas shows.
    public var renderingContext: CIContext {
        context
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange _: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            logger.error("Canvas draw skipped: no drawable or command buffer")
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        logger.debug("Canvas draw: texture \(drawable.texture.width)x\(drawable.texture.height)")
        guard render(image, into: drawable.texture, commandBuffer: commandBuffer,
                     pointScale: view.drawableSize.width / max(view.bounds.width, 1)) else { return }
        commandBuffer.addCompletedHandler { [weak self] _ in
            let duration = clock.now - start
            Task { @MainActor in self?.lastRenderDuration = duration }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Encodes the drawing of `image` (fitted, zoomed and panned) over a black background into `texture`.
    /// Separated from `draw(in:)` so it can be exercised off screen.
    /// - Parameter pointScale: pixels per point of the view, to convert the pan offset.
    @discardableResult
    func render(_ image: CIImage?, into texture: MTLTexture, commandBuffer: MTLCommandBuffer, pointScale: CGFloat) -> Bool {
        let size = CGSize(width: texture.width, height: texture.height)
        let bounds = CGRect(origin: .zero, size: size)
        let background = CIImage(color: .black).cropped(to: bounds)
        let composed = image.map { placed($0, in: size, scaleFactor: pointScale).composited(over: background) } ?? background

        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = colorSpace
        destination.alphaMode = .premultiplied
        do {
            try context.startTask(toRender: composed, from: bounds, to: destination, at: .zero)
            return true
        } catch {
            logger.error("Canvas render failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Fits the image in the drawable, then applies zoom and pan around the center.
    private func placed(_ image: CIImage, in drawableSize: CGSize, scaleFactor: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let fit = min(drawableSize.width / extent.width, drawableSize.height / extent.height)
        let scale = fit * zoom
        let scaledSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        let origin = CGPoint(
            x: (drawableSize.width - scaledSize.width) / 2 + panOffset.x * scaleFactor,
            y: (drawableSize.height - scaledSize.height) / 2 - panOffset.y * scaleFactor
        )
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}
