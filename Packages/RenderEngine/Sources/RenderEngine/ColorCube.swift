import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel
import Foundation
import Synchronization

/// Builds 3D lookup tables for per-color adjustments that Core Image has no filter for, and applies
/// them with CIColorCubeWithColorSpace in sRGB.
nonisolated enum ColorCube {
    /// Points per axis. 33 is the usual compromise between smoothness and the cost of building it.
    static let dimension = 33

    /// RGBA float cube data for an RGB transform expressed in 0…1 display values.
    static func data(dimension: Int = dimension, transform: (Double, Double, Double) -> (red: Double, green: Double, blue: Double)) -> Data {
        var floats = [Float32](repeating: 0, count: dimension * dimension * dimension * 4)
        var offset = 0
        for blue in 0 ..< dimension {
            for green in 0 ..< dimension {
                for red in 0 ..< dimension {
                    let step = Double(dimension - 1)
                    let output = transform(Double(red) / step, Double(green) / step, Double(blue) / step)
                    floats[offset] = Float32(output.red.clamped(to: 0 ... 1))
                    floats[offset + 1] = Float32(output.green.clamped(to: 0 ... 1))
                    floats[offset + 2] = Float32(output.blue.clamped(to: 0 ... 1))
                    floats[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Cube for a selective color setting, kept for the last few settings: moving another slider or
    /// undoing shouldn't rebuild it, and the preview, the histogram and the export share it.
    static func data(for hsl: HSL) -> Data {
        if let cached = cache.withLock({ $0.first { $0.key == hsl }?.data }) {
            return cached
        }
        let evaluator = HSL.Evaluator(hsl)
        let built = data { evaluator.apply(red: $0, green: $1, blue: $2) }
        cache.withLock { entries in
            entries.insert((hsl, built), at: 0)
            if entries.count > 4 {
                entries.removeLast()
            }
        }
        return built
    }

    private static let cache = Mutex<[(key: HSL, data: Data)]>([])

    static func apply(_ cube: Data, dimension: Int = dimension, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(dimension)
        filter.cubeData = cube
        filter.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        return filter.outputImage ?? image
    }
}

private nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
