import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Encodes a rendered image to a file format. Runs off the main actor: full-size rendering takes time.
public nonisolated enum ImageExporter {
    public enum ExportError: Error, LocalizedError {
        case encodingFailed

        public var errorDescription: String? {
            "The image couldn't be encoded."
        }
    }

    /// Full-resolution JPEG in sRGB, as most viewers expect.
    public static func jpegData(for image: CIImage, quality: Double = 0.92) throws -> Data {
        let context = CIContext(options: [.cacheIntermediates: false])
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
        else {
            throw ExportError.encodingFailed
        }
        return data
    }
}
