import CoreGraphics
import CoreImage
import EditModel

/// Applies a recipe's geometry (turns, flip, straightening, crop) to an image. Output extent starts at
/// the origin so the adjustments and the canvas see a plain image.
public nonisolated enum GeometryRenderer {
    public static func apply(_ geometry: Geometry, to image: CIImage) -> CIImage {
        var output = image
        if geometry.isFlippedHorizontally {
            output = output.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).moved(toOrigin: true)
        }
        if geometry.quarterTurns != 0 {
            // Clockwise turns are negative rotations in Core Image's counterclockwise convention.
            let radians = -Double(geometry.quarterTurns) * .pi / 2
            output = output.transformed(by: CGAffineTransform(rotationAngle: radians)).moved(toOrigin: true)
        }

        let straight = output.extent
        if geometry.angle != 0 {
            output = output.transformed(by: CGAffineTransform(rotationAngle: -geometry.angle * .pi / 180)).moved(toOrigin: true)
        }
        let safe = safeArea(for: straight.size, rotatedExtent: output.extent, degrees: geometry.angle)
        let crop = geometry.crop
        // The crop's origin is at the top-left; Core Image's is at the bottom-left.
        let cropRect = CGRect(
            x: safe.minX + crop.x * safe.width,
            y: safe.minY + (1 - crop.y - crop.height) * safe.height,
            width: crop.width * safe.width,
            height: crop.height * safe.height
        ).integral
        return output.cropped(to: cropRect).moved(toOrigin: true)
    }

    /// Largest rectangle with the straight image's aspect ratio inside the rotated image, centered.
    static func safeArea(for size: CGSize, rotatedExtent: CGRect, degrees: Double) -> CGRect {
        let scale = Geometry.inscribedScale(width: size.width, height: size.height, degrees: degrees)
        let safeSize = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rotatedExtent.midX - safeSize.width / 2, y: rotatedExtent.midY - safeSize.height / 2,
                      width: safeSize.width, height: safeSize.height)
    }
}

private nonisolated extension CIImage {
    /// Translates the image so its extent starts at (0, 0).
    func moved(toOrigin _: Bool) -> CIImage {
        let origin = extent.origin
        guard origin != .zero, !extent.isInfinite else { return self }
        return transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}
