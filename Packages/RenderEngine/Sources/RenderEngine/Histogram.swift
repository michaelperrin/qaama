import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Luminance distribution of an image per channel, 256 bins each, normalized so the tallest bin is 1.
public nonisolated struct Histogram: Hashable, Sendable {
    public static let binCount = 256

    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Per-channel maximum over the three channels, for drawing them on one scale.
    public var luminance: [Float] {
        (0 ..< Self.binCount).map { max(red[$0], green[$0], blue[$0]) }
    }
}

/// Computes histograms with Core Image's area histogram filter, on a reduced copy of the image so the
/// cost stays flat whatever the photo size.
public nonisolated enum HistogramComputer {
    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Qaama histogram"])
    /// Long edge of the sample the histogram is computed on.
    static let sampleSize: CGFloat = 512

    public static func compute(_ image: CIImage) -> Histogram? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let scale = min(1, sampleSize / max(extent.width, extent.height))
        // Core Image works in linear, extended-range light; a histogram is read in display values, so encode
        // to sRGB and clamp: blown-out pixels must pile up in the last bin instead of being dropped.
        let sample = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])

        let filter = CIFilter.areaHistogram()
        filter.inputImage = sample
        filter.extent = sample.extent
        filter.count = Histogram.binCount
        filter.scale = 1
        guard let output = filter.outputImage else { return nil }

        var pixels = [Float](repeating: 0, count: Histogram.binCount * 4)
        context.render(output, toBitmap: &pixels, rowBytes: Histogram.binCount * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: Histogram.binCount, height: 1), format: .RGBAf, colorSpace: nil)

        var red = [Float](repeating: 0, count: Histogram.binCount)
        var green = red
        var blue = red
        for bin in 0 ..< Histogram.binCount {
            red[bin] = pixels[bin * 4]
            green[bin] = pixels[bin * 4 + 1]
            blue[bin] = pixels[bin * 4 + 2]
        }
        // Normalize on the interior bins: clipped shadows and highlights pile up in the first and last bins
        // and would squash everything else. Those two bins are capped at 1 and read as "walls".
        let interior = 1 ..< (Histogram.binCount - 1)
        var peak = max(red[interior].max() ?? 0, green[interior].max() ?? 0, blue[interior].max() ?? 0)
        if peak == 0 {
            peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0)
        }
        guard peak > 0 else { return nil }
        func normalized(_ bins: [Float]) -> [Float] {
            bins.map { min($0 / peak, 1) }
        }
        return Histogram(red: normalized(red), green: normalized(green), blue: normalized(blue))
    }
}
