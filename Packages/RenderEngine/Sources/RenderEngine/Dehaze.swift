import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Removes, or adds, atmospheric haze with the dark channel prior (He, Sun and Tang, 2009), built
/// from Core Image's own filters so it needs no custom kernel.
///
/// A hazy pixel is `scene × t + airlight × (1 − t)`, where the transmission `t` falls with the
/// thickness of the haze. The haze is read from the dark channel, the minimum of red, green and blue
/// blurred over a wide neighborhood: a clear scene has a dark channel near zero almost everywhere, and
/// haze lifts it. The airlight is the brightest value of that channel. Everything runs in the
/// context's linear working space, after white balance and exposure, so the estimate does not depend
/// on the tone adjustments that follow.
nonisolated enum Dehaze {
    /// Long edge, in pixels, of the image the dark channel is estimated on. The channel is a smooth,
    /// low-frequency plane, so a small analysis keeps the blur cheap whatever the source size.
    static let analysisLongEdge: CGFloat = 512
    /// Blur radius of the dark channel, as a fraction of the analysis long edge.
    static let blurFraction: CGFloat = 0.02
    /// Share of the estimated veil a full-strength slider removes (1 would divide by zero).
    static let strength = 0.95
    /// Lowest transmission allowed: dividing by less amplifies noise and color casts without limit.
    static let minimumTransmission = 0.12
    /// Floor of the airlight, in linear light: a dark image has no veil to remove.
    static let minimumAirlight = 0.05

    /// `amount` is the slider value, -1 (add haze) to +1 (remove all the haze found).
    static func apply(_ amount: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard amount != 0, !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        let dark = darkChannel(of: image)
        let airlight = airlight(of: dark)
        // How much of the airlight each pixel carries: the smooth dark channel, but never more than
        // the pixel's own darkest channel, or dark subjects next to bright areas would go black.
        let ownMinimum = CIFilter.minimumComponent()
        ownMinimum.inputImage = image
        let veil = clamp(minimum(divide(dark, by: airlight), divide(ownMinimum.outputImage ?? image, by: airlight)), 0, 1)

        // Compositing filters that add alpha (CIAdditionCompositing) break the division that follows:
        // the arithmetic below only uses blend modes and masks, which keep alpha at 1.
        let output: CIImage
        if amount > 0 {
            // t = max(1 − strength × amount × veil, minimum); out = (c − A × (1 − t)) / t
            let transmission = clamp(scale(veil, by: -strength * min(amount, 1), bias: 1), minimumTransmission, 1)
            // A × (1 − t) never exceeds the pixel's own minimum (the veil is bounded by it), so the
            // clamping subtraction loses nothing.
            let removed = multiply(airlight, scale(transmission, by: -1, bias: 1))
            output = divide(subtract(removed, from: image), by: transmission)
        } else {
            // Blend toward a slightly dimmed airlight, more where there is already haze:
            // out = c × (1 − k) + 0.9 × A × k, with k growing with the veil.
            let k = 0.7 * min(-amount, 1)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = scale(airlight, by: 0.9, bias: 0)
            blend.backgroundImage = image
            blend.maskImage = scale(veil, by: 0.65 * k, bias: 0.35 * k)
            output = blend.outputImage ?? image
        }
        return output.cropped(to: extent)
    }

    /// Minimum channel of a reduced copy, blurred, brought back to the image's size. Cached by Core Image
    /// across renders: it only changes when the image before it does, not on every slider move.
    static func darkChannel(of image: CIImage) -> CIImage {
        let extent = image.extent
        let factor = min(1, analysisLongEdge / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let minimum = CIFilter.minimumComponent()
        minimum.inputImage = small.clampedToExtent()
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = minimum.outputImage
        blur.radius = Float(blurFraction * max(small.extent.width, small.extent.height))
        let blurred = (blur.outputImage ?? small).cropped(to: small.extent)
        return blurred
            .transformed(by: CGAffineTransform(scaleX: 1 / factor, y: 1 / factor))
            .cropped(to: extent)
            .insertingIntermediate(cache: true)
    }

    /// The brightest value of the dark channel, as an infinite constant image so it can take part in
    /// per-pixel arithmetic without leaving the GPU.
    static func airlight(of dark: CIImage) -> CIImage {
        let maximum = CIFilter.areaMaximum()
        maximum.inputImage = dark
        maximum.extent = dark.extent
        let value = maximum.outputImage ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        return clamp(value, minimumAirlight, 1e6).insertingIntermediate(cache: true).clampedToExtent()
    }

    // MARK: Per-pixel arithmetic on Core Image's compositing filters

    /// `numerator / denominator`, per channel.
    static func divide(_ numerator: CIImage, by denominator: CIImage) -> CIImage {
        let filter = CIFilter.divideBlendMode()
        filter.inputImage = denominator
        filter.backgroundImage = numerator
        return filter.outputImage ?? numerator
    }

    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }

    /// `image − amount`, per channel, clamped at zero.
    static func subtract(_ amount: CIImage, from image: CIImage) -> CIImage {
        let filter = CIFilter.subtractBlendMode()
        filter.inputImage = amount
        filter.backgroundImage = image
        return filter.outputImage ?? image
    }

    static func minimum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.minimumCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }

    /// `value × factor + bias` on the color channels, alpha untouched. Negative results are kept: the
    /// working format is floating point.
    static func scale(_ image: CIImage, by factor: Double, bias: Double) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: factor, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: factor, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: factor, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        return filter.outputImage ?? image
    }

    static func clamp(_ image: CIImage, _ low: Double, _ high: Double) -> CIImage {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: low, y: low, z: low, w: 0)
        filter.maxComponents = CIVector(x: high, y: high, z: high, w: 1)
        return filter.outputImage ?? image
    }
}
