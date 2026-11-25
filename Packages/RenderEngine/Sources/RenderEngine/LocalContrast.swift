import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Texture and clarity: contrast added to, or taken from, the details of one size, leaving the
/// overall tones where they are.
///
/// Both read the detail as the gap, in stops, between a pixel's luminance and a smoothed copy of
/// it, then brighten or darken the pixel by a share of that gap. Texture smooths over a few pixels
/// (pores, bark, fabric), clarity over a wide neighborhood with an edge-aware filter, so it lifts
/// local contrast without drawing halos along the horizon. Working in stops treats shadows and
/// highlights alike, and scaling the three channels by one gain keeps the colors.
///
/// The settings and the formulas are those of LightCraft (`crates/pipeline/src/finish.rs`,
/// `local_tone_delta`, and `craft-libs` `crates/develop/src/local.rs`; MIT or Apache 2.0,
/// github.com/storytold/lightcraft), rewritten with Core Image's own filters, without a custom
/// kernel: the functions of one value (logarithm, shape of the detail) are lookup tables built
/// once, and the slider only sets an exponent, so nothing is built per slider move.
nonisolated enum LocalContrast {
    // MARK: Settings, as in LightCraft

    /// Blur of the texture band, as a fraction of the image's long edge, and its floor in pixels.
    static let textureSigmaFraction = 0.0018
    static let minimumTextureSigma = 0.6
    /// Stops added per stop of detail by a full texture slider.
    static let textureStrength = 1.1
    /// Share of that strength a negative texture keeps: smoothing reads stronger than sharpening.
    static let negativeTextureShare = 0.67

    /// Reach of the clarity band, as a fraction of the image's long edge, and its floor in pixels.
    static let claritySigmaFraction = 0.012
    static let minimumClaritySigma = 1.0
    /// How much two tones must differ to count as an edge the clarity band keeps, in stops squared.
    static let clarityEpsilon = 0.8
    /// Stops added per stop of detail by a full clarity slider, in the midtones.
    static let clarityStrength = 0.85
    /// Largest detail clarity acts on, in stops.
    static let clarityLimit = 2.5
    /// Share of the clarity kept in the deepest shadows and the brightest highlights.
    static let clarityOutsideMidtones = 0.35
    /// Width, in stops around middle gray, of the tones that get the whole clarity.
    static let midtoneWidth = 3.2

    /// `texture` and `clarity` are the slider values, -1 (smoother) to +1 (crisper).
    static func apply(texture: Double, clarity: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard texture != 0 || clarity != 0, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        let longEdge = max(extent.width, extent.height)
        let stops = encodedStops(of: image)
        // Both smooth a reduced copy of the image: what they blur away is not there to lose, and
        // the full-size image is then read once, by the reduction, instead of once per blur.
        let textureSigma = max(textureSigmaFraction * longEdge, minimumTextureSigma)
        let textureReduction = reduction(forSigma: textureSigma, pixelsKept: 2.5)
        let textureCopy = reduced(image, by: textureReduction)
        var gain: CIImage?

        if texture != 0 {
            let smooth = enlarged(smoothed(encodedStops(of: textureCopy), sigma: textureSigma / textureReduction), to: extent)
            let shape = curve(textureTable, domain: detailDomain, on: detail(of: stops, against: smooth))
            let amount = texture.clamped(to: -1 ... 1)
            gain = raise(shape, to: textureStrength * (amount < 0 ? amount * negativeTextureShare : amount), scale: textureScale)
        }

        if clarity != 0 {
            let sigma = max(claritySigmaFraction * longEdge, minimumClaritySigma)
            let clarityReduction = max(reduction(forSigma: sigma, pixelsKept: 3), textureReduction)
            let copy = reduced(textureCopy, by: clarityReduction / textureReduction)
            let (base, mean) = edgeAwareBase(of: stops, reduced: encodedStops(of: copy), sigma: sigma / clarityReduction)
            let shape = curve(clarityTable, domain: detailDomain, on: detail(of: stops, against: base))
            let full = raise(shape, to: clarityStrength * clarity.clamped(to: -1 ... 1), scale: clarityScale)
            // Less of it away from the midtones, read on the local mean so an area is weighted as a whole.
            let blend = CIFilter.blendWithMask()
            blend.inputImage = full
            blend.backgroundImage = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            blend.maskImage = curve(midtoneTable, domain: 0 ... 1, on: mean)
            let weighted = (blend.outputImage ?? full).cropped(to: extent)
            gain = gain.map { multiply($0, weighted) } ?? weighted
        }

        guard let gain else { return image }
        return multiply(gain, image).cropped(to: extent)
    }

    // MARK: Luminance in stops

    /// Darkest and brightest luminance told apart, in stops from middle gray, and that gray in
    /// linear light. Outside, the detail reads as flat.
    static let stopsFloor = -10.0
    static let stopsSpan = 14.0
    static let middleGray = 0.18
    /// Entries of the lookup tables.
    static let tableSize = 1024

    /// The image's luminance in stops from middle gray, brought to 0…1 over `stopsSpan`, as an
    /// opaque gray image.
    static func encodedStops(of image: CIImage) -> CIImage {
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luminance = CIFilter.colorMatrix()
        luminance.inputImage = image
        luminance.rVector = weights
        luminance.gVector = weights
        luminance.bVector = weights
        luminance.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        luminance.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let positive = CIFilter.colorClamp()
        positive.inputImage = luminance.outputImage
        positive.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        positive.maxComponents = CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1)
        // A table indexed by linear light would give the shadows a handful of entries: the cube
        // root spreads them first.
        let root = CIFilter.gammaAdjust()
        root.inputImage = positive.outputImage
        root.power = 1 / 3
        // Making the gray opaque gave it no bounds: back to the image's.
        return curve(stopsTable, domain: 0 ... rootCeiling, on: root.outputImage ?? image).cropped(to: image.extent)
    }

    /// Cube root of the brightest luminance the encoding tells apart.
    static let rootCeiling = cbrt(middleGray * exp2(stopsFloor + stopsSpan))

    static func encodedStops(ofLuminance luminance: Double) -> Double {
        ((log2(max(luminance, 1e-7) / middleGray) - stopsFloor) / stopsSpan).clamped(to: 0 ... 1)
    }

    private static let stopsTable = table { root in encodedStops(ofLuminance: root * root * root) }

    // MARK: Detail

    /// Largest gap between a pixel and its smoothed copy the tables cover, in stops.
    static let detailReach = 3.0
    /// Where `detail(of:against:)` puts gaps of ±`detailReach`.
    static var detailDomain: ClosedRange<Double> {
        0.5 - detailReach / (2 * stopsSpan) ... 0.5 + detailReach / (2 * stopsSpan)
    }

    /// `0.5 + (stops − smooth) / 2`: the signed gap, kept positive for the filters that follow.
    static func detail(of stops: CIImage, against smooth: CIImage) -> CIImage {
        let inverted = CIFilter.colorInvert()
        inverted.inputImage = smooth
        let mix = CIFilter.mix()
        mix.inputImage = stops
        mix.backgroundImage = inverted.outputImage
        mix.amount = 0.5
        return mix.outputImage ?? stops
    }

    /// Stops a full texture slider adds for a detail of `gap` stops, before `textureStrength`: the
    /// detail itself up to one stop, eased off on strong edges so they don't ring.
    static func textureShape(_ gap: Double) -> Double {
        gap.clamped(to: -1 ... 1) * (1 - 0.6 * smoothstep(0.4, 1.6, abs(gap)))
    }

    /// The same for clarity, before `clarityStrength` and the weight of the midtones.
    static func clarityShape(_ gap: Double) -> Double {
        gap.clamped(to: -clarityLimit ... clarityLimit)
    }

    /// Share of the clarity a tone gets, from its distance to middle gray in stops.
    static func midtoneWeight(stops: Double) -> Double {
        clarityOutsideMidtones + (1 - clarityOutsideMidtones) * exp(-(stops / midtoneWidth) * (stops / midtoneWidth))
    }

    /// The tables hold the gain of a slider at full strength, divided so it fits under 1; `raise`
    /// turns it into the gain of any strength.
    static let textureScale = 2.0
    static let clarityScale = exp2(clarityLimit + 0.5)

    private static let textureTable = table(over: detailDomain) { exp2(textureShape(($0 - 0.5) * 2 * stopsSpan)) / textureScale }
    private static let clarityTable = table(over: detailDomain) { exp2(clarityShape(($0 - 0.5) * 2 * stopsSpan)) / clarityScale }
    private static let midtoneTable = table(over: 0 ... 1) { midtoneWeight(stops: $0 * stopsSpan + stopsFloor) }

    /// `(shape × scale) ^ exponent`: two stops of gain at full strength are one at half. The only
    /// step that depends on the slider.
    static func raise(_ shape: CIImage, to exponent: Double, scale: Double) -> CIImage {
        let power = CIFilter.gammaAdjust()
        power.inputImage = shape
        power.power = Float(exponent)
        let factor = pow(scale, exponent)
        let scaled = CIFilter.colorMatrix()
        scaled.inputImage = power.outputImage
        scaled.rVector = CIVector(x: factor, y: 0, z: 0, w: 0)
        scaled.gVector = CIVector(x: 0, y: factor, z: 0, w: 0)
        scaled.bVector = CIVector(x: 0, y: 0, z: factor, w: 0)
        scaled.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return scaled.outputImage ?? shape
    }

    // MARK: Clarity's base

    /// The tones without their local contrast: smoothed, but not across the edges between areas of
    /// different tones. This is the guided filter (He, Sun and Tang, 2010) with the image as its
    /// own guide, `base = keep × stops + rest`: where the tones vary little against
    /// `clarityEpsilon`, `keep` is near 0 and the base is the local mean; along an edge it is near
    /// 1 and the base follows the image. `keep` and `rest` are smooth, so they are worked out on
    /// the reduced copy (the fast guided filter, He and Sun, 2015), over `sigma` of its pixels,
    /// and only the last step runs at full size. `mean` is the plain local mean, at full size.
    ///
    /// Core Image's own `CIGuidedFilter` was tried first: it reduces its guide without averaging
    /// it, and a fine pattern came back as waves stronger than the pattern itself.
    static func edgeAwareBase(of stops: CIImage, reduced small: CIImage, sigma: Double) -> (base: CIImage, mean: CIImage) {
        let extent = stops.extent
        let mean = smoothed(small, sigma: sigma)
        // The variance from the gaps to the local mean: small numbers, which half floats hold
        // precisely, where the mean of the squares minus the square of the mean would not be.
        let gap = CIFilter.colorAbsoluteDifference()
        gap.inputImage = small
        gap.inputImage2 = mean
        let variance = smoothed(multiply(gap.outputImage ?? small, gap.outputImage ?? small), sigma: sigma)
        let epsilon = clarityEpsilon / (stopsSpan * stopsSpan)
        let padded = CIFilter.colorMatrix()
        padded.inputImage = variance
        padded.biasVector = CIVector(x: epsilon, y: epsilon, z: epsilon, w: 0)
        let ratio = CIFilter.divideBlendMode()
        ratio.inputImage = padded.outputImage?.cropped(to: small.extent)
        ratio.backgroundImage = variance
        let keep = (ratio.outputImage ?? variance).cropped(to: small.extent)
        let inverted = CIFilter.colorInvert()
        inverted.inputImage = keep
        let rest = multiply(inverted.outputImage ?? keep, mean).cropped(to: small.extent)

        // keep × stops + rest, as twice their average: the compositing filters that add would add
        // the alphas too.
        let sum = CIFilter.mix()
        sum.inputImage = multiply(enlarged(smoothed(keep, sigma: sigma), to: extent), stops)
        sum.backgroundImage = enlarged(smoothed(rest, sigma: sigma), to: extent)
        sum.amount = 0.5
        let doubled = CIFilter.colorMatrix()
        doubled.inputImage = sum.outputImage
        doubled.rVector = CIVector(x: 2, y: 0, z: 0, w: 0)
        doubled.gVector = CIVector(x: 0, y: 2, z: 0, w: 0)
        doubled.bVector = CIVector(x: 0, y: 0, z: 2, w: 0)
        return ((doubled.outputImage ?? stops).cropped(to: extent), enlarged(mean, to: extent))
    }

    // MARK: Reduced copies

    /// Largest reduction of the copy a blur is worked out on.
    static let largestReduction = 16.0

    /// How many times smaller an image can be made before a blur of `sigma` pixels, keeping the
    /// blur at least `pixelsKept` pixels wide on the copy: a power of two, 1 for no reduction.
    static func reduction(forSigma sigma: Double, pixelsKept: Double) -> Double {
        var reduction = 1.0
        while reduction < largestReduction, sigma / (reduction * 2) >= pixelsKept {
            reduction *= 2
        }
        return reduction
    }

    /// A copy `factor` times smaller, each pixel the average of those it stands for: one pixel in
    /// sixteen picked as it is would put the photo's noise in what is meant to be smooth.
    static func reduced(_ image: CIImage, by factor: Double) -> CIImage {
        guard factor > 1 else { return image }
        // The first halving as a plain scale, which reads four pixels for one and runs in a single
        // pass over the full-size image; Core Image's own reduction takes two passes per halving.
        let half = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        guard factor > 2 else { return half }
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = half
        scale.scale = Float(2 / factor)
        scale.aspectRatio = 1
        guard let small = scale.outputImage, small.extent.width >= 1, small.extent.height >= 1 else { return half }
        return small
    }

    /// A reduced copy back at the size and place of the image it came from.
    static func enlarged(_ small: CIImage, to extent: CGRect) -> CIImage {
        let from = small.extent
        guard from != extent else { return small }
        let transform = CGAffineTransform(translationX: -from.minX, y: -from.minY)
            .concatenating(CGAffineTransform(scaleX: extent.width / from.width, y: extent.height / from.height))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return small.clampedToExtent().transformed(by: transform).cropped(to: extent)
    }

    /// Blurred within its own bounds: the borders are held, not faded to nothing.
    static func smoothed(_ image: CIImage, sigma: Double) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(sigma)
        return (blur.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: Helpers

    static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = ((value - low) / (high - low)).clamped(to: 0 ... 1)
        return t * t * (3 - 2 * t)
    }

    /// `function` sampled over `domain`, the same in the three channels, as `CIColorCurves` reads it.
    private static func table(over domain: ClosedRange<Double> = 0 ... rootCeiling, _ function: (Double) -> Double) -> Data {
        var samples = [Float32](repeating: 0, count: tableSize * 3)
        for index in 0 ..< tableSize {
            let input = domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double(index) / Double(tableSize - 1)
            let value = Float32(function(input))
            samples[index * 3] = value
            samples[index * 3 + 1] = value
            samples[index * 3 + 2] = value
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Applies a table to a gray image. The table is read in linear values, which a gray keeps in
    /// any linear working space; inputs outside `domain` take the table's ends.
    private static func curve(_ table: Data, domain: ClosedRange<Double>, on image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorCurves"), let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(table, forKey: "inputCurvesData")
        filter.setValue(CIVector(x: domain.lowerBound, y: domain.upperBound), forKey: "inputCurvesDomain")
        filter.setValue(linear, forKey: "inputColorSpace")
        return filter.outputImage ?? image
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? b
    }
}

private nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
