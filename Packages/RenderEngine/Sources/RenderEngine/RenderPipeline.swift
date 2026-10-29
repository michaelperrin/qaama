import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel

/// Turns an `EditRecipe` into a Core Image filter chain. Pure function of its inputs.
public nonisolated enum RenderPipeline {
    public static func apply(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        var output = image
        if recipe.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(recipe.exposure)
            output = exposure.outputImage ?? output
        }
        if recipe.contrast != 0 || recipe.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = output
            controls.contrast = contrastFactor(recipe.contrast)
            controls.saturation = saturationFactor(recipe.saturation)
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
