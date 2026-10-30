import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel
import Foundation

/// Turns a `Mask` into a grayscale image covering the reference image (white = fully selected).
///
/// Gradients and ranges are computed here; machine-learned components come precomputed in
/// `resolved`, keyed by component id, and are skipped when missing.
public nonisolated enum MaskRenderer {
    public static func render(_ mask: Mask, reference: CIImage, resolved: [UUID: CIImage] = [:]) -> CIImage? {
        let extent = reference.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        var combined: CIImage?
        for component in mask.components {
            guard let image = render(component.kind, reference: reference, resolved: resolved[component.id]) else { continue }
            guard let current = combined else {
                combined = component.operation == .add ? image : nil
                continue
            }
            switch component.operation {
            case .add: combined = maximum(current, image)
            case .subtract: combined = multiply(current, invert(image, extent: extent))
            case .intersect: combined = multiply(current, image)
            }
        }
        guard var result = combined else { return nil }
        if mask.feather > 0 {
            let radius = Float(mask.feather * 0.05 * max(extent.width, extent.height))
            result = result.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: extent)
        }
        if mask.isInverted {
            result = invert(result, extent: extent)
        }
        if mask.density < 1 {
            result = scaled(result, by: mask.density)
        }
        return result
    }

    // MARK: - Components

    static func render(_ kind: MaskKind, reference: CIImage, resolved: CIImage?) -> CIImage? {
        let extent = reference.extent
        switch kind {
        case .subject, .background, .people, .sky, .scene:
            // Model-based components arrive precomputed.
            return resolved.map { $0.cropped(to: extent) }
        case let .brush(brush):
            return BrushRenderer.render(brush, extent: extent)
        case let .linearGradient(gradient):
            return linearGradient(gradient, extent: extent)
        case let .radialGradient(gradient):
            return radialGradient(gradient, extent: extent)
        case let .luminosity(range):
            return luminosity(range, reference: reference)
        case let .color(range):
            return color(range, reference: reference)
        }
    }

    /// White before `start`, fading to black at `end`.
    static func linearGradient(_ gradient: LinearGradientMask, extent: CGRect) -> CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = pixelPoint(gradient.start, in: extent)
        filter.point1 = pixelPoint(gradient.end, in: extent)
        filter.color0 = .white
        filter.color1 = .black
        return (filter.outputImage ?? CIImage(color: .black)).cropped(to: extent)
    }

    /// An ellipse, built from a circular gradient scaled and rotated around its center.
    static func radialGradient(_ gradient: RadialGradientMask, extent: CGRect) -> CIImage {
        let long = max(extent.width, extent.height)
        let filter = CIFilter.radialGradient()
        filter.center = .zero
        let radius = Float(long * gradient.radiusX)
        filter.radius0 = radius * Float(1 - gradient.softness)
        filter.radius1 = radius
        filter.color0 = .white
        filter.color1 = .black
        guard let circle = filter.outputImage else { return CIImage(color: .black).cropped(to: extent) }
        let center = pixelPoint(gradient.center, in: extent)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -gradient.angle * .pi / 180)
            .scaledBy(x: 1, y: gradient.radiusY / gradient.radiusX)
        return circle.transformed(by: transform).cropped(to: extent)
    }

    /// Luminance of the reference, mapped through the range's weight as a 256-step curve.
    static func luminosity(_ range: LuminosityRange, reference: CIImage) -> CIImage {
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let gray = reference.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let samples = (0 ..< 256).map { Float32(range.weight(Double($0) / 255)) }
        var data = [Float32](repeating: 0, count: 256 * 3)
        for index in 0 ..< 256 {
            data[index * 3] = samples[index]
            data[index * 3 + 1] = samples[index]
            data[index * 3 + 2] = samples[index]
        }
        guard let filter = CIFilter(name: "CIColorCurves"), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return gray }
        filter.setValue(gray, forKey: kCIInputImageKey)
        filter.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCurvesData")
        filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        filter.setValue(colorSpace, forKey: "inputColorSpace")
        return filter.outputImage ?? gray
    }

    /// Hue and saturation window evaluated through a 3D cube: each color maps to its gray weight.
    static func color(_ range: ColorRange, reference: CIImage) -> CIImage {
        let cube = ColorCube.data(dimension: 17) { r, g, b in
            let (h, s, _) = HSL.rgbToHSL(r, g, b)
            let weight = range.weight(hue: h, saturation: s)
            return (weight, weight, weight)
        }
        return ColorCube.apply(cube, dimension: 17, to: reference)
    }

    // MARK: - Combination

    static func maximum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.maximumCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }

    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }

    static func invert(_ image: CIImage, extent: CGRect) -> CIImage {
        image.applyingFilter("CIColorInvert").cropped(to: extent)
    }

    static func scaled(_ image: CIImage, by factor: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
        ])
    }

    /// Unit point (origin top-left) to Core Image pixel coordinates (origin bottom-left).
    static func pixelPoint(_ point: UnitPoint2D, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
    }
}
