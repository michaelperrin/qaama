import CoreImage
import CoreVideo
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

    /// The largest zoom the gestures, the slider and the menu allow.
    public static let maximumZoom: CGFloat = 16

    /// What the gestures, the slider and the menu keep `zoom` within. It starts at Fit, since
    /// nothing is gained by showing the photo smaller than the view allows, or at 100% for a photo
    /// smaller than the view, which Fit enlarges.
    public var zoomRange: ClosedRange<CGFloat> {
        min(1, actualSizeZoom ?? 1) ... Self.maximumZoom
    }

    /// Size of the view's drawable in pixels, as last laid out; zero before the view has one.
    public private(set) var drawableSize: CGSize = .zero

    /// The zoom at which one pixel of the image is one pixel of the screen, or nil without an image
    /// or a view to show it in. Above `maximumZoom` for an image much larger than the view.
    public var actualSizeZoom: CGFloat? {
        guard let image else { return nil }
        let fit = Self.fitScale(imageSize: image.extent.size, in: drawableSize)
        return fit > 0 ? 1 / fit : nil
    }

    /// Screen pixels per image pixel when the whole image fits the drawable (zoom 1); 0 when either
    /// size is unknown.
    public nonisolated static func fitScale(imageSize: CGSize, in drawableSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, drawableSize.width > 0, drawableSize.height > 0 else { return 0 }
        return min(drawableSize.width / imageSize.width, drawableSize.height / imageSize.height)
    }

    /// Zooms around the center, within `zoomRange`. At Fit or below the whole photo is in view and
    /// there is nothing to pan to, so it goes back to the center.
    public func setZoom(_ value: CGFloat) {
        let range = zoomRange
        zoom = min(max(value, range.lowerBound), range.upperBound)
        if zoom <= 1, panOffset != .zero {
            panOffset = .zero
        }
    }

    /// Offset of the image center from the view center, in view points.
    public var panOffset: CGPoint = .zero {
        didSet { view?.setNeedsDisplay(view?.bounds ?? .zero) }
    }

    /// GPU time of the last frame, for the latency measurements of the proof of concept.
    public private(set) var lastRenderDuration: Duration?

    /// Frames drawn since the last reset, with the main-thread time spent encoding them and the
    /// time until the GPU finished. The editor sums them over a gesture to say where a slow
    /// brush stroke spends its time.
    public struct DrawStats: Sendable {
        public var frames = 0
        public var encode: Duration = .zero
        public var completion: Duration = .zero
    }

    public private(set) var drawStats = DrawStats()

    /// The image of the last frame the GPU finished: equal to `image` once the canvas has caught up
    /// with it. Lets a caller wait until what it asked for is really on screen, however long the
    /// first render of a RAW takes.
    @ObservationIgnored public private(set) var presentedImage: CIImage?

    public func resetDrawStats() {
        drawStats = DrawStats()
    }

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

    /// Decodes `image` now, off the main actor, and returns it as pixels the canvas draws at once:
    /// an image of the same extent and values, backed by memory the caller owns for as long as it
    /// keeps the result. Meant for the draft of a photo the user may step to next.
    ///
    /// Core Image's own cache of intermediates can't be relied on for this: once a few full-size
    /// decodes fill it, it evicts drafts decoded ahead in no predictable order (measured: 40 ms or
    /// 600 ms for the same step). Half-float pixels in the working space keep values above one.
    ///
    /// At user-initiated priority on purpose: a RAW is mostly decompressed on the CPU, and a
    /// lower priority sends that to the efficiency cores, three times slower (measured). What keeps
    /// it out of the way of the photo on screen is when the caller starts it, not its priority.
    public func rasterized(_ image: CIImage) async -> CIImage? {
        let context = context
        return await Task.detached(priority: .userInitiated) {
            let extent = image.extent.integral
            guard !extent.isInfinite, extent.width >= 1, extent.height >= 1, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](), kCVPixelBufferMetalCompatibilityKey: true]
            var created: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, Int(extent.width), Int(extent.height), kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &created) == kCVReturnSuccess,
                  let buffer = created else { return nil }
            // Rendered from the origin, then moved back: the buffer has no notion of the extent's origin.
            let destination = CIRenderDestination(pixelBuffer: buffer)
            destination.colorSpace = space
            let atOrigin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            guard let task = try? context.startTask(toRender: atOrigin, from: CGRect(origin: .zero, size: extent.size), to: destination, at: .zero),
                  (try? task.waitUntilCompleted()) != nil else { return nil }
            return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        }.value
    }

    /// Shared Core Image context, for exports that must match what the canvas shows.
    public var renderingContext: CIContext {
        context
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        view.setNeedsDisplay(view.bounds)
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            logger.error("Canvas draw skipped: no drawable or command buffer")
            return
        }
        if drawableSize != view.drawableSize {
            drawableSize = view.drawableSize
        }
        let clock = ContinuousClock()
        let start = clock.now
        logger.debug("Canvas draw: texture \(drawable.texture.width)x\(drawable.texture.height)")
        guard render(image, into: drawable.texture, commandBuffer: commandBuffer,
                     pointScale: view.drawableSize.width / max(view.bounds.width, 1)) else { return }
        drawStats.frames += 1
        drawStats.encode += clock.now - start
        let drawn = image
        commandBuffer.addCompletedHandler { [weak self] _ in
            let duration = clock.now - start
            Task { @MainActor in
                self?.lastRenderDuration = duration
                self?.drawStats.completion += duration
                self?.presentedImage = drawn
            }
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
        let scale = Self.fitScale(imageSize: extent.size, in: drawableSize) * zoom
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
