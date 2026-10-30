import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

/// Turns an `EditRecipe` into a Core Image filter chain. Pure function of its inputs.
///
/// Layers are applied in order; within a layer the adjustments run in the engine's fixed order:
/// white balance, exposure, highlights and shadows, black point, contrast, curves, color, selective color, detail, black and white, then effects. Masks are carried by the
/// recipe but not rendered yet.
public nonisolated enum RenderPipeline {
    public static func apply(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        apply(recipe, to: image, geometry: recipe.geometry)
    }

    /// Same, with the geometry overridden: the crop tool shows the straightened image without its crop.
    public static func apply(_ recipe: EditRecipe, to image: CIImage, geometry: Geometry?) -> CIImage {
        var current = image
        if let geometry, !geometry.isIdentity {
            current = GeometryRenderer.apply(geometry, to: current)
        }
        return recipe.layers.reduce(current) { current, layer in
            guard layer.isEnabled, !layer.adjustments.isIdentity else { return current }
            return apply(layer.adjustments, to: current)
        }
    }

    public static func apply(_ adjustments: AdjustmentSet, to image: CIImage) -> CIImage {
        var output = image

        let temperature = adjustments.temperature ?? 0
        let tint = adjustments.tint ?? 0
        if temperature != 0 || tint != 0 {
            let balance = CIFilter.temperatureAndTint()
            balance.inputImage = output
            balance.neutral = CIVector(x: 6500, y: 0)
            // Moving the target away from neutral shifts the image the other way: a lower target
            // temperature makes the image warmer, which is what the slider promises.
            balance.targetNeutral = CIVector(x: 6500 - temperature * Self.temperatureSpan, y: -tint * Self.tintSpan)
            output = balance.outputImage ?? output
        }

        if let ev = adjustments.exposure, ev != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(ev)
            output = exposure.outputImage ?? output
        }

        let highlights = adjustments.highlights ?? 0
        let shadows = adjustments.shadows ?? 0
        if highlights != 0 || shadows != 0 {
            let tones = CIFilter.highlightShadowAdjust()
            tones.inputImage = output
            // The filter only recovers highlights (1 = untouched, 0.3 = strongest). Lifting them is a
            // gentle tone-curve push on the upper range instead.
            tones.highlightAmount = Float(1 + min(highlights, 0) * 0.7)
            tones.shadowAmount = Float(shadows)
            tones.radius = 8
            output = tones.outputImage ?? output
            if highlights > 0 {
                let curve = CIFilter.toneCurve()
                curve.inputImage = output
                curve.point0 = CGPoint(x: 0, y: 0)
                curve.point1 = CGPoint(x: 0.25, y: 0.25)
                curve.point2 = CGPoint(x: 0.5, y: 0.5)
                curve.point3 = CGPoint(x: 0.75, y: 0.75 + highlights * 0.12)
                curve.point4 = CGPoint(x: 1, y: 1)
                output = curve.outputImage ?? output
            }
        }

        if let blackPoint = adjustments.blackPoint, blackPoint != 0 {
            // A tone curve anchored at the black end: negative values push the darkest input to black,
            // positive values raise what black maps to. The rest of the curve stays on the diagonal.
            let curve = CIFilter.toneCurve()
            curve.inputImage = output
            curve.point0 = blackPoint < 0 ? CGPoint(x: -blackPoint * Self.blackPointSpan, y: 0) : CGPoint(x: 0, y: blackPoint * Self.blackPointSpan)
            curve.point1 = CGPoint(x: 0.25, y: 0.25)
            curve.point2 = CGPoint(x: 0.5, y: 0.5)
            curve.point3 = CGPoint(x: 0.75, y: 0.75)
            curve.point4 = CGPoint(x: 1, y: 1)
            output = curve.outputImage ?? output
        }

        let contrast = adjustments.contrast ?? 0
        let saturation = adjustments.saturation ?? 0
        if contrast != 0 || saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = contrastFactor(contrast)
            controls.saturation = saturationFactor(saturation)
            controls.brightness = 0
            output = controls.outputImage ?? output
        }

        if let curves = adjustments.curves, !curves.isIdentity {
            output = applyCurves(curves, to: output)
        }

        if let vibrance = adjustments.vibrance, vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(vibrance)
            output = filter.outputImage ?? output
        }

        if let noise = adjustments.noiseReduction, noise > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = output
            filter.noiseLevel = Float(noise * 0.1)
            filter.sharpness = 0.4
            output = filter.outputImage ?? output
        }

        if let sharpness = adjustments.sharpness, sharpness != 0 {
            if sharpness > 0 {
                let filter = CIFilter.unsharpMask()
                filter.inputImage = output
                filter.radius = 1.5
                filter.intensity = Float(sharpness * 1.5)
                output = filter.outputImage ?? output
            } else {
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = output
                blur.radius = Float(-sharpness * 2)
                // The blur grows the extent; keep the image's own frame.
                output = (blur.outputImage ?? output).cropped(to: output.extent)
            }
        }

        if let hsl = adjustments.hsl, !hsl.isIdentity {
            output = ColorCube.apply(ColorCube.data(for: hsl), to: output)
        }

        if let monochrome = adjustments.monochrome {
            let weights = monochrome.weights
            let mix = CIVector(x: weights.red, y: weights.green, z: weights.blue, w: 0)
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = output
            matrix.rVector = mix
            matrix.gVector = mix
            matrix.bVector = mix
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            output = matrix.outputImage ?? output
        }

        if let grain = adjustments.grain, grain > 0 {
            output = applyGrain(grain, to: output)
        }

        if let vignette = adjustments.vignette, vignette != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = output
            let extent = output.extent
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.radius = Float(hypot(extent.width, extent.height) / 2)
            filter.intensity = Float(vignette)
            filter.falloff = 0.5
            output = filter.outputImage ?? output
        }
        return output
    }

    /// Film-like grain: position-based noise (so preview and export match), reduced to gray, centered on
    /// mid-gray with a strength set by the slider, then overlaid on the image.
    static func applyGrain(_ amount: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite else { return image }
        let strength = amount * 0.35
        let gray = CIVector(x: 0.33, y: 0.33, z: 0.34, w: 0)
        let noise = CIFilter.randomGenerator().outputImage?
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": gray, "inputGVector": gray, "inputBVector": gray,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            // Scale the noise around 0.5: 0.5 + (n - 0.5) * strength.
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
                "inputBiasVector": CIVector(x: 0.5 * (1 - strength), y: 0.5 * (1 - strength), z: 0.5 * (1 - strength), w: 0),
            ])
            .transformed(by: CGAffineTransform(scaleX: 1.6, y: 1.6))
            .cropped(to: extent)
        guard let noise else { return image }
        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = noise
        blend.backgroundImage = image
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    /// Samples per channel in the curve lookup table handed to Core Image.
    static let curveSamples = 256

    /// Tone curves through CIColorCurves, evaluated in sRGB so the curve maps display values as in
    /// every other editor, not linear light.
    static func applyCurves(_ curves: Curves, to image: CIImage) -> CIImage {
        let tables = curves.lookupTables(count: curveSamples)
        var data = [Float32](repeating: 0, count: curveSamples * 3)
        for index in 0 ..< curveSamples {
            data[index * 3] = Float32(tables.red[index])
            data[index * 3 + 1] = Float32(tables.green[index])
            data[index * 3 + 2] = Float32(tables.blue[index])
        }
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let filter = CIFilter(name: "CIColorCurves"), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(bytes, forKey: "inputCurvesData")
        filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        filter.setValue(colorSpace, forKey: "inputColorSpace")
        return filter.outputImage ?? image
    }

    /// How far the black point moves (in linear input or output) at the end of its slider.
    static let blackPointSpan = 0.15

    /// Kelvin covered by the full temperature slider on either side of neutral.
    static let temperatureSpan = 2500.0
    /// Tint units of CITemperatureAndTint covered by the full tint slider.
    static let tintSpan = 100.0

    /// Maps the recipe's -1…+1 contrast to CIColorControls' multiplicative factor (1 = neutral).
    static func contrastFactor(_ value: Double) -> Float {
        Float(1 + value * 0.5)
    }

    /// Maps the recipe's -1…+1 saturation to CIColorControls' factor (0 = grayscale, 1 = neutral, 2 = double).
    static func saturationFactor(_ value: Double) -> Float {
        Float(1 + value)
    }
}
