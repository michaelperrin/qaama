import CoreGraphics
import CoreImage
import EditModel

/// Applies a recipe's geometry in two steps: `straighten` gives the reference image masks are
/// defined in (flipped, turned, straightened, trimmed of empty corners); `crop` cuts the final frame.
/// Output extents start at the origin so the adjustments and the canvas see plain images.
public nonisolated enum GeometryRenderer {
    public static func apply(_ geometry: Geometry, to image: CIImage) -> CIImage {
        crop(straighten(image, with: geometry), with: geometry)
    }

    /// Flip, quarter turns and straightening, cropped to the safe area (no empty corners).
    public static func straighten(_ image: CIImage, with geometry: Geometry) -> CIImage {
        var output = image
        if geometry.isFlippedHorizontally {
            output = output.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).movedToOrigin()
        }
        if geometry.quarterTurns != 0 {
            // Clockwise turns are negative rotations in Core Image's counterclockwise convention.
            let radians = -Double(geometry.quarterTurns) * .pi / 2
            output = output.transformed(by: CGAffineTransform(rotationAngle: radians)).movedToOrigin()
        }
        guard geometry.angle != 0 else { return output }
        let straight = output.extent
        output = output.transformed(by: CGAffineTransform(rotationAngle: -geometry.angle * .pi / 180)).movedToOrigin()
        let safe = safeArea(for: straight.size, rotatedExtent: output.extent, degrees: geometry.angle)
        return output.cropped(to: safe.integral).movedToOrigin()
    }

    /// The crop frame, expressed in the reference image's unit coordinates (origin top-left).
    public static func crop(_ reference: CIImage, with geometry: Geometry) -> CIImage {
        let crop = geometry.crop
        guard !crop.isFull else { return reference }
        let extent = reference.extent
        // The crop's origin is at the top-left; Core Image's is at the bottom-left.
        let cropRect = CGRect(
            x: extent.minX + crop.x * extent.width,
            y: extent.minY + (1 - crop.y - crop.height) * extent.height,
            width: crop.width * extent.width,
            height: crop.height * extent.height
        ).integral
        return reference.cropped(to: cropRect).movedToOrigin()
    }

    /// Largest rectangle with the straight image's aspect ratio inside the rotated image, centered.
    static func safeArea(for size: CGSize, rotatedExtent: CGRect, degrees: Double) -> CGRect {
        let scale = Geometry.inscribedScale(width: size.width, height: size.height, degrees: degrees)
        let safeSize = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rotatedExtent.midX - safeSize.width / 2, y: rotatedExtent.midY - safeSize.height / 2,
                      width: safeSize.width, height: safeSize.height)
    }
}

nonisolated extension CIImage {
    /// Translates the image so its extent starts at (0, 0).
    func movedToOrigin() -> CIImage {
        let origin = extent.origin
        guard origin != .zero, !extent.isInfinite else { return self }
        return transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}
