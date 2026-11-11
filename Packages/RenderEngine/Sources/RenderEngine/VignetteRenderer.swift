import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

/// Renders a `Vignette`: the image darkened or brightened everywhere, blended over the untouched
/// image through a falloff fitted to the frame. Built from Core Image's own filters, so it needs no
/// custom kernel; everything runs in the context's linear working space.
///
/// How the settings map to the shape (`Shape`) and to the blend follows the post-crop vignette of
/// LightCraft (`crates/pipeline/src/finish.rs`, © 2026 ArtCraft Team and the LightCraft
/// contributors, MIT or Apache 2.0, https://github.com/storytold/lightcraft), rewritten here for
/// Core Image.
nonisolated enum VignetteRenderer {
    /// Share of the way to white a full brightening vignette takes its strongest point.
    static let brighteningStrength = 0.85
    /// Luminance, in linear light, from which the highlights start to resist a darkening vignette;
    /// they resist fully at 1.
    static let highlightThreshold = 0.4

    /// The falloff of a vignette in a frame of a given aspect ratio: pure numbers, so the Core Image
    /// chain below and the tests share one definition.
    struct Shape: Equatable {
        /// Distance at which the effect starts and width of the fade. Distances are 1 at the middle
        /// of the frame's sides for an oval; the corners are further out.
        let start: Double
        let width: Double
        /// Exponent of the superellipse: 2 is an ellipse, more squares it toward the frame.
        let power: Double
        /// What the horizontal and vertical coordinates (-1…1 across the frame) are multiplied by
        /// before measuring the distance: 1 and 1 follow the frame, less on one axis rounds the
        /// shape toward a circle.
        let scaleX: Double
        let scaleY: Double

        init(_ vignette: Vignette, aspectRatio: Double) {
            start = 0.15 + vignette.midpoint * 0.95
            // Never zero: a hard edge would alias, and no lens draws one.
            width = 0.05 + vignette.feather * 1.1
            power = vignette.roundness >= 0 ? 2 : 2 + -vignette.roundness * 6
            let mix = min(max((vignette.roundness + 1) / 2, 0), 1)
            let x = 1 + (aspectRatio - 1) * mix, y = 1 + (1 / aspectRatio - 1) * mix
            scaleX = max(x, 1) / max(x, y)
            scaleY = max(y, 1) / max(x, y)
        }

        /// Share of the effect, 0 to 1, at a point of the frame given in -1…1 on both axes.
        func weight(x: Double, y: Double) -> Double {
            let distance = pow(pow(abs(x * scaleX), power) + pow(abs(y * scaleY), power), 1 / power)
            return VignetteRenderer.smoothstep((distance - start) / width)
        }
    }

    /// `frame` is the rectangle the vignette is fitted to, in the image's coordinates: the crop when
    /// there is one, so the vignette follows the final frame and not the original.
    static func apply(_ vignette: Vignette, to image: CIImage, frame: CGRect) -> CIImage {
        guard !vignette.isNeutral, !frame.isInfinite, frame.width > 0, frame.height > 0 else { return image }
        var mask = falloff(Shape(vignette, aspectRatio: frame.width / frame.height), frame: frame)
        let amount = vignette.amount
        let target: CIImage
        if amount < 0 {
            // Toward black: the image times `1 + amount` where the mask is white.
            target = affine(image, scale: 1 + amount, bias: 0)
            if vignette.highlights > 0 {
                mask = MaskRenderer.multiply(mask, highlightResistance(vignette.highlights, in: image))
            }
        } else {
            // Toward white, never pulling down what is already brighter than white (HDR highlights).
            let strength = amount * brighteningStrength
            target = MaskRenderer.maximum(affine(image, scale: 1 - strength, bias: strength), image)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = target
        blend.backgroundImage = image
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }

    /// The share of the effect each pixel gets, as a gray image: black where the photo is untouched,
    /// white where the effect is whole. Outside the frame it keeps the value of the frame's edge.
    static func falloff(_ shape: Shape, frame: CGRect) -> CIImage {
        // Red carries the horizontal position and green the vertical one, both 0…1 across the frame.
        let horizontal = ramp(from: CGPoint(x: frame.minX, y: frame.midY), to: CGPoint(x: frame.maxX, y: frame.midY),
                              color: CIColor(red: 1, green: 0, blue: 0))
        let vertical = ramp(from: CGPoint(x: frame.midX, y: frame.minY), to: CGPoint(x: frame.midX, y: frame.maxY),
                            color: CIColor(red: 0, green: 1, blue: 0))
        var image = MaskRenderer.maximum(horizontal, vertical)
        // (2p − 1)² = 1 − 4p + 4p²: the squared coordinate around the center, scaled for the shape.
        image = image.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": squaredCoordinate(scaledBy: shape.scaleX),
            "inputGreenCoefficients": squaredCoordinate(scaledBy: shape.scaleY),
            "inputBlueCoefficients": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        // Superellipse distance: (|x|ᵖ + |y|ᵖ)^(1/p), from the squares raised to p/2.
        if shape.power != 2 {
            image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": shape.power / 2])
        }
        let sum = CIVector(x: 1, y: 1, z: 0, w: 0)
        image = image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": sum, "inputGVector": sum, "inputBVector": sum])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / shape.power])
        // Smoothstep between where the effect starts and where it is whole.
        return eased(affine(image, scale: 1 / shape.width, bias: -shape.start / shape.width))
    }

    /// How much of a darkening vignette each pixel keeps: 1 in the dark and middle tones, down to
    /// `1 − highlights` for the brightest ones.
    static func highlightResistance(_ highlights: Double, in image: CIImage) -> CIImage {
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luminance = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luma, "inputGVector": luma, "inputBVector": luma, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let span = 1 - highlightThreshold
        let bright = eased(affine(luminance, scale: 1 / span, bias: -highlightThreshold / span))
        return affine(bright, scale: -highlights, bias: 1)
    }

    static func smoothstep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Building blocks

    /// Black up to `start`, `color` from `end` on, a linear ramp in between. Infinite.
    private static func ramp(from start: CGPoint, to end: CGPoint, color: CIColor) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = start
        gradient.point1 = end
        gradient.color0 = .black
        gradient.color1 = color
        return gradient.outputImage ?? CIImage(color: .black)
    }

    /// Coefficients of `scale² × (2p − 1)²` for CIColorPolynomial, constant term first.
    private static func squaredCoordinate(scaledBy scale: Double) -> CIVector {
        let square = scale * scale
        return CIVector(x: square, y: -4 * square, z: 4 * square, w: 0)
    }

    /// `scale × value + bias` on the three color channels.
    private static func affine(_ image: CIImage, scale: Double, bias: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }

    /// Clamps to 0…1 then applies smoothstep (3t² − 2t³), so no ring shows where a fade starts or ends.
    private static func eased(_ image: CIImage) -> CIImage {
        let ease = CIVector(x: 0, y: 0, z: 3, w: -2)
        return image
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": ease, "inputGreenCoefficients": ease, "inputBlueCoefficients": ease,
            ])
    }
}
