import CoreGraphics
import Foundation
import ImageIO

/// Turns what a device hands over into images, off the main actor.
nonisolated enum CameraThumbnails {
    /// How much of a file to read for its embedded thumbnail. Measured on Canon and Fuji JPEG files:
    /// the EXIF thumbnail (160 × 120) is within the first 128 kB.
    static let headLength = 131_072

    /// The thumbnail a camera embedded in the file's header, oriented for display; nil when these
    /// bytes hold none. Never a decode of the image itself, which `head` only has the top of.
    static func embedded(inHead head: Data) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Embedded thumbnails are 160 px; the limit only keeps ImageIO from handing back more.
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let source = CGImageSourceCreateWithData(head as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The middle of `image` at the photo's own shape (width over height). Cameras embed a 4:3
    /// thumbnail whatever the photo's shape, with black bands above and below a 3:2 photo: seen on
    /// Canon and Fuji files. Unchanged when the shapes already agree, or the photo's is unknown.
    static func cropped(_ image: CGImage, toAspectRatio ratio: Double) -> CGImage {
        guard ratio > 0, image.width > 0, image.height > 0 else { return image }
        let (width, height) = (Double(image.width), Double(image.height))
        var size = CGSize(width: width, height: height)
        // A pixel more off each side: the edge of a band falls between two rows of pixels, and
        // what is left of it shows as a dark line (seen on the first captures).
        if width / height < ratio {
            size.height = (width / ratio).rounded(.down) - 2
        } else {
            size.width = (height * ratio).rounded(.down) - 2
        }
        // A pixel or two of difference is rounding, not bands.
        guard width - size.width > 4 || height - size.height > 4, size.width > 0, size.height > 0 else { return image }
        let rect = CGRect(x: ((width - size.width) / 2).rounded(), y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
        return image.cropping(to: rect) ?? image
    }

    /// Decodes an image the device encoded, at its own size, with whatever orientation it says applied.
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
