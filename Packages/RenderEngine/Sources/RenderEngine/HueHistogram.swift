import CoreImage
import EditModel
import Foundation

/// How much of each hue an image holds: one bin per degree, counting the pixels that have a color
/// (grays weigh nothing, faint colors little). Normalized so the tallest bin is 1; all zeros for
/// an image without color.
public nonisolated struct HueHistogram: Hashable, Sendable {
    public static let binCount = 360

    public let bins: [Float]

    public init(bins: [Float]) {
        self.bins = bins
    }

    /// One bar of a display of the histogram.
    public struct Bar: Hashable, Sendable {
        /// The hue in the middle of the bar, in degrees.
        public let hue: Double
        /// 0 to 1; the tallest bar of a histogram is 1.
        public let height: Float
    }

    /// Bars for a display that gives every color range of the mixer the same width, so each range's
    /// hues stand above its swatch (see `HSL.hue(atStripPosition:)`). A bar is the average of the
    /// bins it covers: ranges are not equally wide in degrees, and a sum would favor the wide ones.
    ///
    /// Heights are the cube root of the share of the tallest bar: the display is there to show
    /// which hues a photo holds more than in what proportion, and on a linear scale one dominant
    /// color (a sky of a single blue) leaves every other hue a few percent of the height. Only the
    /// tallest bar reaches 1, so nothing ever looks clipped.
    public func bars(perRange: Int) -> [Bar] {
        let count = HSL.ColorRange.allCases.count * max(perRange, 1)
        let step = 1 / Double(max(perRange, 1))
        var bars: [(hue: Double, value: Double)] = []
        bars.reserveCapacity(count)
        for index in 0 ..< count {
            let start = HSL.hue(atStripPosition: Double(index) * step)
            var span = HSL.hue(atStripPosition: Double(index + 1) * step) - start
            if span <= 0 {
                span += 360
            }
            // The bins the bar covers, the first and last ones in part.
            var sum = 0.0
            var degree = start.rounded(.down)
            while degree < start + span {
                let overlap = min(degree + 1, start + span) - max(degree, start)
                sum += Double(bins[Int(degree) % Self.binCount]) * overlap
                degree += 1
            }
            bars.append((HSL.hue(atStripPosition: (Double(index) + 0.5) * step), sum / span))
        }
        let peak = bars.map(\.value).max() ?? 0
        return bars.map { Bar(hue: $0.hue, height: peak > 0 ? Float(cbrt($0.value / peak)) : 0) }
    }
}

/// Computes hue histograms on a small copy of the image: the distribution of hues does not need
/// more, and the pixels are counted in Swift, one by one.
public nonisolated enum HueHistogramComputer {
    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Qaama hue histogram"])
    /// Long edge of the sample: at most 25,600 pixels to count.
    static let sampleSize: CGFloat = 160
    /// Below this difference between the strongest and the weakest channel (of 255), a pixel is
    /// gray: its hue is noise.
    static let minimumChroma = 10
    /// From this difference on, a pixel counts in full; fainter colors count in proportion. Vivid
    /// pixels do not count more than plainly colored ones: the histogram shows how much of the
    /// photo each hue covers.
    static let fullWeightChroma = 32

    public static func compute(_ image: CIImage) -> HueHistogram? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let scale = min(1, sampleSize / max(extent.width, extent.height))
        let sample = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(Int(sample.extent.width), 1), height = max(Int(sample.extent.height), 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // In display values, as the hues are seen: the context encodes to sRGB and clamps.
        context.render(sample, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: sample.extent.minX.rounded(.down), y: sample.extent.minY.rounded(.down), width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return histogram(ofRGBA: pixels)
    }

    /// The histogram of 8-bit RGBA pixels in display values. Integer arithmetic and no allocation
    /// per pixel: this also runs in Debug builds.
    static func histogram(ofRGBA pixels: [UInt8]) -> HueHistogram {
        var bins = [Float](repeating: 0, count: HueHistogram.binCount)
        pixels.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset + 3 < buffer.count {
                let red = Int(buffer[offset]), green = Int(buffer[offset + 1]), blue = Int(buffer[offset + 2])
                offset += 4
                let maximum = max(red, green, blue)
                let chroma = maximum - min(red, green, blue)
                guard chroma >= minimumChroma else { continue }
                // The usual hexagon, in degrees: 60 per sector, rounded down to the bin.
                var hue = if maximum == red {
                    60 * (green - blue) / chroma
                } else if maximum == green {
                    120 + 60 * (blue - red) / chroma
                } else {
                    240 + 60 * (red - green) / chroma
                }
                if hue < 0 {
                    hue += 360
                } else if hue >= 360 {
                    hue -= 360
                }
                bins[hue] += Float(min(chroma, fullWeightChroma))
            }
        }
        let peak = bins.max() ?? 0
        return HueHistogram(bins: peak > 0 ? bins.map { $0 / peak } : bins)
    }
}
