import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Stamps a watermark on a photo: text drawn by Core Image or a picture, scaled to a share of the
/// photo's width, with an optional shadow, an opacity, placed at an anchor or tiled. Scale
/// independent, like the frame.
nonisolated enum WatermarkRenderer {
    /// Point size the text is drawn at before scaling; large enough to stay sharp on big exports.
    static let textPointSize: Float = 256
    /// Distance from the photo's edges as a fraction of its short edge.
    static let marginFraction = 0.03
    /// Gap between tiles as a fraction of the stamp's width.
    static let tileGapFraction = 0.6

    /// `picture` is the decoded image for an image watermark; a missing picture leaves the photo as is.
    static func apply(_ watermark: ExportWatermark, to photo: CIImage, picture: CIImage?) -> CIImage {
        guard watermark.isEnabled, !photo.extent.isInfinite, photo.extent.width > 0, var stamp = stamp(for: watermark, picture: picture), stamp.extent.width > 0, stamp.extent.height > 0 else { return photo }
        let targetWidth = watermark.size * photo.extent.width
        stamp = scaled(stamp, toWidth: targetWidth)
        if watermark.hasShadow {
            stamp = withShadow(stamp)
        }
        stamp = faded(stamp, to: watermark.opacity)
        let placed: CIImage
        if watermark.isTiled {
            let gap = stamp.extent.width * tileGapFraction
            let cell = CGRect(x: 0, y: 0, width: stamp.extent.width + gap, height: stamp.extent.height + gap)
            let padded = stamp
                .transformed(by: CGAffineTransform(translationX: gap / 2 - stamp.extent.minX, y: gap / 2 - stamp.extent.minY))
                .composited(over: CIImage(color: .clear).cropped(to: cell))
            let tile = CIFilter.affineTile()
            tile.inputImage = padded
            tile.transform = .identity
            placed = (tile.outputImage ?? padded)
                .transformed(by: CGAffineTransform(translationX: photo.extent.minX, y: photo.extent.minY))
        } else {
            let margin = marginFraction * min(photo.extent.width, photo.extent.height)
            let anchor = watermark.position.anchor
            let x = photo.extent.minX + margin + anchor.x * (photo.extent.width - 2 * margin - stamp.extent.width)
            let y = photo.extent.minY + margin + anchor.y * (photo.extent.height - 2 * margin - stamp.extent.height)
            placed = stamp.transformed(by: CGAffineTransform(translationX: (x - stamp.extent.minX).rounded(), y: (y - stamp.extent.minY).rounded()))
        }
        return placed.composited(over: photo).cropped(to: photo.extent)
    }

    /// The watermark at its drawing size, origin at zero, transparent where there is nothing.
    static func stamp(for watermark: ExportWatermark, picture: CIImage?) -> CIImage? {
        switch watermark.kind {
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let generator = CIFilter.textImageGenerator()
            generator.text = trimmed
            generator.fontName = watermark.fontName
            generator.fontSize = textPointSize
            generator.scaleFactor = 1
            guard let drawn = generator.outputImage else { return nil }
            return tinted(drawn, with: FrameRenderer.ciColor(watermark.color))
        case .image:
            guard let picture, !picture.extent.isInfinite else { return nil }
            return picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
        }
    }

    /// A solid color shaped by the image's alpha.
    static func tinted(_ image: CIImage, with color: CIColor) -> CIImage {
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = CIImage(color: color).cropped(to: image.extent)
        blend.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
        blend.maskImage = image
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }

    static func scaled(_ image: CIImage, toWidth width: CGFloat) -> CIImage {
        let factor = width / image.extent.width
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(factor)
        filter.aspectRatio = 1
        let output = filter.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return output.cropped(to: CGRect(x: 0, y: 0, width: (image.extent.width * factor).rounded(), height: (image.extent.height * factor).rounded()))
    }

    /// A soft dark copy under the stamp, offset toward the bottom right, so light marks stay readable on
    /// light photos.
    static func withShadow(_ stamp: CIImage) -> CIImage {
        let offset = max(1, stamp.extent.height * 0.04)
        let shadow = faded(tinted(stamp, with: .black), to: 0.6)
            .applyingGaussianBlur(sigma: Double(offset))
            .transformed(by: CGAffineTransform(translationX: offset, y: -offset))
        return stamp.composited(over: shadow)
    }

    /// Scales the alpha channel; color filters see unpremultiplied pixels, so the colors stay as they are.
    static func faded(_ image: CIImage, to opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
        return filter.outputImage ?? image
    }
}
