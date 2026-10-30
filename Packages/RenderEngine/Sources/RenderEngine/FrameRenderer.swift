import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Draws the export frame: a solid canvas with the photo centered on it, its corners rounded when
/// asked. Works at any scale since the frame is described in fractions of the photo.
nonisolated enum FrameRenderer {
    static func apply(_ frame: ExportFrame, to photo: CIImage) -> CIImage {
        guard frame.isEnabled, !photo.extent.isInfinite else { return photo }
        let moved = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.minX, y: -photo.extent.minY))
        let layout = frame.layout(for: moved.extent.size)
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        let background = CIImage(color: ciColor(frame.color)).cropped(to: canvas)
        let placed = moved.transformed(by: CGAffineTransform(translationX: layout.photoOrigin.x, y: layout.photoOrigin.y))
        let radius = frame.cornerRadius * min(moved.extent.width, moved.extent.height)
        guard radius > 0 else { return placed.composited(over: background).cropped(to: canvas) }
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = placed.extent
        generator.radius = Float(radius)
        generator.color = .white
        let blend = CIFilter.blendWithMask()
        blend.inputImage = placed
        blend.backgroundImage = background
        blend.maskImage = generator.outputImage
        return (blend.outputImage ?? placed.composited(over: background)).cropped(to: canvas)
    }

    static func ciColor(_ color: ExportColor) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? .white
    }
}
