import CoreGraphics
import CoreImage
import Foundation
import UniformTypeIdentifiers

/// Where the pixels of a photo come from.
public nonisolated enum RenderSource: Sendable {
    /// A file on disk, RAW or not. RAW files go through Apple's RAW engine (`CIRAWFilter`).
    case file(URL)
    /// An already decoded image, as PhotoKit hands them out.
    case image(CGImage)
}

/// A decoded photo ready for the pipeline, plus what the UI needs to know about it.
public nonisolated struct SourceImage: Sendable {
    public let image: CIImage
    public let isRAW: Bool
    public var pixelSize: CGSize {
        image.extent.size
    }
}

/// Decodes a `RenderSource` into a `CIImage`. Decoding is lazy in Core Image, but RAW demosaicing is
/// expensive, so the result is marked as a cacheable intermediate: the pipeline downstream re-runs on
/// every slider change, the RAW stage does not.
public nonisolated enum SourceImageLoader {
    public enum LoadError: Error, LocalizedError {
        case unreadable(URL)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(url): "The image “\(url.lastPathComponent)” can't be decoded."
            }
        }
    }

    public static func load(_ source: RenderSource) throws -> SourceImage {
        switch source {
        case let .image(cgImage):
            return SourceImage(image: CIImage(cgImage: cgImage).insertingIntermediate(cache: true), isRAW: false)
        case let .file(url):
            if isRAW(url), let raw = CIRAWFilter(imageURL: url), let output = raw.outputImage {
                return SourceImage(image: output.insertingIntermediate(cache: true), isRAW: true)
            }
            guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw LoadError.unreadable(url)
            }
            return SourceImage(image: image.insertingIntermediate(cache: true), isRAW: false)
        }
    }

    public static func isRAW(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .rawImage)
    }
}
