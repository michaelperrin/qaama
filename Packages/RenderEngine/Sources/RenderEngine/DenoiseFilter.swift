import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Noise reduction on an already decoded image, for the photos Apple's RAW engine doesn't decode
/// (JPEG, HEIC…) and the RAW files it has no noise settings for. Built from Core Image's own
/// filters, so it needs no custom kernel. Simple on purpose: it knows nothing of the sensor.
///
/// Both steps run on display values (the sRGB curve), where noise is about as strong in the shadows
/// as in the highlights; in linear light a single strength would wipe the shadows or miss them.
nonisolated enum DenoiseFilter {
    /// Blur of the colors at the end of the slider, in pixels of the image (Gaussian sigma). Color
    /// noise comes in blotches several pixels wide; beyond this the colors of small things bleed.
    static let colorRadius = 8.0
    /// Scale of the copy the colors are blurred on. JPEG and HEIC files store their colors at half
    /// the resolution anyway, and a blur over four times fewer pixels keeps the slider within a
    /// frame: 4 to 11 ms per position for 26 MP fitted in the view, against 15 to 70 ms at full scale.
    static let colorScale = 0.5
    /// `CINoiseReduction`'s threshold at the end of the slider: the top of that filter's own range.
    static let luminanceLevel = 0.1
    /// Rec. 709 weights of the luma the colors are measured against.
    static let lumaWeights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)

    static func apply(_ amounts: DenoiseAmounts, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard amounts.luminance > 0 || amounts.color > 0, !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        let toDisplay = CIFilter.linearToSRGBToneCurve()
        toDisplay.inputImage = image
        var output = toDisplay.outputImage ?? image
        if amounts.color > 0 {
            output = smoothingColors(of: output, radius: amounts.color * colorRadius)
        }
        if amounts.luminance > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = output
            filter.noiseLevel = Float(amounts.luminance * luminanceLevel)
            filter.sharpness = 0.4
            output = filter.outputImage ?? output
        }
        let toLinear = CIFilter.sRGBToneCurveToLinear()
        toLinear.inputImage = output
        return (toLinear.outputImage ?? output).cropped(to: extent)
    }

    /// The image with its own luma and the colors of a blurred copy: the speckles go, the detail,
    /// which the eye reads in the luma, stays. An edge between two saturated colors softens a little.
    static func smoothingColors(of image: CIImage, radius: Double) -> CIImage {
        // The colors alone (the image minus its luma, around zero), blurred on a reduced copy.
        let scale = colorScale
        let reduced = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = matrix(reduced, red: CIVector(x: 1 - lumaWeights.x, y: -lumaWeights.y, z: -lumaWeights.z, w: 0),
                                 green: CIVector(x: -lumaWeights.x, y: 1 - lumaWeights.y, z: -lumaWeights.z, w: 0),
                                 blue: CIVector(x: -lumaWeights.x, y: -lumaWeights.y, z: 1 - lumaWeights.z, w: 0))
        blur.radius = Float(radius * scale)
        let colors = (blur.outputImage ?? reduced).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)).cropped(to: image.extent)
        // luma + colors, per channel. Core Image's adding filters add the alphas too: the mean of the
        // two keeps it at one, and is then doubled.
        let mix = CIFilter.mix()
        mix.inputImage = matrix(image, red: lumaWeights, green: lumaWeights, blue: lumaWeights)
        mix.backgroundImage = colors
        mix.amount = 0.5
        return matrix(mix.outputImage ?? image, red: CIVector(x: 2, y: 0, z: 0, w: 0), green: CIVector(x: 0, y: 2, z: 0, w: 0),
                      blue: CIVector(x: 0, y: 0, z: 2, w: 0))
    }

    /// A linear mix of the color channels, alpha untouched. Negative results are kept: the working
    /// format is floating point.
    private static func matrix(_ image: CIImage, red: CIVector, green: CIVector, blue: CIVector) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = red
        filter.gVector = green
        filter.bVector = blue
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }
}
