import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

/// Turns an `EditRecipe` into a Core Image filter chain. Pure function of its inputs.
///
/// Layers are applied in order; within a layer the adjustments run in the engine's fixed order:
/// white balance, exposure, highlights and shadows, contrast, then color. Masks are carried by the
/// recipe but not rendered yet.
public nonisolated enum RenderPipeline {
    public static func apply(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        recipe.layers.reduce(image) { current, layer in
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

        if let vibrance = adjustments.vibrance, vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(vibrance)
            output = filter.outputImage ?? output
        }
        return output
    }

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
