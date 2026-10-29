import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

/// Turns an `EditRecipe` into a Core Image filter chain. Pure function of its inputs.
///
/// Layers are applied in order; within a layer the adjustments run in the engine's fixed order
/// (light first, then color). Masks are carried by the recipe but not rendered yet.
public nonisolated enum RenderPipeline {
    public static func apply(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        recipe.layers.reduce(image) { current, layer in
            guard layer.isEnabled, !layer.adjustments.isIdentity else { return current }
            return apply(layer.adjustments, to: current)
        }
    }

    public static func apply(_ adjustments: AdjustmentSet, to image: CIImage) -> CIImage {
        var output = image
        if let ev = adjustments.exposure, ev != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(ev)
            output = exposure.outputImage ?? output
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
        return output
    }

    /// Maps the recipe's -1…+1 contrast to CIColorControls' multiplicative factor (1 = neutral).
    static func contrastFactor(_ value: Double) -> Float {
        Float(1 + value * 0.5)
    }

    /// Maps the recipe's -1…+1 saturation to CIColorControls' factor (0 = grayscale, 1 = neutral, 2 = double).
    static func saturationFactor(_ value: Double) -> Float {
        Float(1 + value)
    }
}
