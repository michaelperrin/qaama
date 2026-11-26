import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel
import Foundation
@testable import RenderEngine
import Testing

/// The pipeline given a reduced copy of a photo, and told its scale, gives what the photo itself
/// would, reduced as much: what the editor shows is what an export holds.
struct RenderPipelineScaleTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let size = CGSize(width: 512, height: 384)

    /// A photo with detail at every scale: a checkerboard of grays under a ramp.
    private var photo: CIImage {
        let checker = CIFilter.checkerboardGenerator()
        checker.color0 = CIColor(red: 0.15, green: 0.15, blue: 0.15)
        checker.color1 = CIColor(red: 0.85, green: 0.8, blue: 0.7)
        checker.width = 12
        checker.sharpness = 1
        let ramp = CIFilter.linearGradient()
        ramp.point0 = .zero
        ramp.point1 = CGPoint(x: size.width, y: 0)
        ramp.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        ramp.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        let extent = CGRect(origin: .zero, size: size)
        return ramp.outputImage!.cropped(to: extent).composited(over: checker.outputImage!.cropped(to: extent))
    }

    private func reduced(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        let width = Int(size.width / 2), height = Int(size.height / 2)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    /// Mean difference between two renders, in levels of 255, away from the borders, where a
    /// filter reads outside the image.
    private func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        let width = Int(size.width / 2), height = Int(size.height / 2), margin = 16
        var sum = 0, count = 0
        for y in margin ..< height - margin {
            for x in margin ..< width - margin {
                for channel in 0 ..< 3 {
                    let index = (y * width + x) * 4 + channel
                    sum += abs(Int(first[index]) - Int(second[index]))
                    count += 1
                }
            }
        }
        return Double(sum) / Double(count)
    }

    @Test(arguments: [
        AdjustmentSet(highlights: -1, shadows: 1),
        AdjustmentSet(sharpness: -1),
        AdjustmentSet(sharpness: 1),
        AdjustmentSet(exposure: 0.4, contrast: 0.3, texture: 0.6, clarity: 0.6),
    ])
    func aReducedCopyRendersLikeThePhotoReduced(adjustments: AdjustmentSet) {
        let recipe = EditRecipe(adjustments: adjustments)
        let expected = pixels(reduced(RenderPipeline.apply(recipe, to: photo)))
        let scaled = pixels(RenderPipeline.apply(recipe, to: reduced(photo), geometry: nil, scale: 0.5))
        #expect(difference(expected, scaled) < 3, "difference of \(difference(expected, scaled)) levels")
    }

    @Test func aRadiusInPixelsIsWrongWithoutTheScale() {
        let recipe = EditRecipe(adjustments: AdjustmentSet(sharpness: -1))
        let expected = pixels(reduced(RenderPipeline.apply(recipe, to: photo)))
        let scaled = pixels(RenderPipeline.apply(recipe, to: reduced(photo), geometry: nil, scale: 0.5))
        let unscaled = pixels(RenderPipeline.apply(recipe, to: reduced(photo)))
        #expect(difference(expected, unscaled) > 2 * difference(expected, scaled))
    }

    @Test func aRetouchFillLandsInTheSamePlaceOnAReducedCopy() {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size))
        let retouch = Retouch(points: [UnitPoint2D(x: 0.5, y: 0.5)], radius: 0.05)
        var recipe = EditRecipe()
        recipe.retouches = [retouch]
        // In the photo's pixels: its middle, 64 pixels wide.
        let fill = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 224, y: 160, width: 64, height: 64))
        let output = pixels(RenderPipeline.apply(recipe, to: reduced(gray), geometry: nil, fills: [retouch.id: fill], scale: 0.5))
        let width = Int(size.width / 2)
        func red(x: Int, y: Int) -> UInt8 {
            output[(y * width + x) * 4]
        }
        #expect(red(x: 128, y: 96) > 250) // the middle of the reduced copy
        #expect(red(x: 150, y: 96) < 200 && red(x: 106, y: 96) < 200) // 32 pixels wide there, not 64
    }

    @Test func aModelMaskMadeAtAnotherSizeIsFittedToTheImage() {
        // Left half selected, on a copy four times smaller than the image it is used on.
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 48))
        let mask = white.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)))
        let extent = CGRect(x: 0, y: 0, width: 256, height: 192)
        let fitted = MaskRenderer.fitted(mask, to: extent)
        #expect(fitted.extent == extent)
        var bytes = [UInt8](repeating: 0, count: 256 * 192 * 4)
        context.render(fitted, toBitmap: &bytes, rowBytes: 256 * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(bytes[(96 * 256 + 60) * 4] > 250 && bytes[(96 * 256 + 200) * 4] < 5)
        #expect(bytes[(191 * 256 + 255) * 4 + 3] == 255) // covered to the far corner
    }
}
