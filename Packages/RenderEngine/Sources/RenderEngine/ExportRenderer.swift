import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import EditModel
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo to export: its decoded pixels, the recipe to render, the model masks already resolved
/// (missing ones are resolved during the render) and, when the source is a file, where to read the
/// metadata to carry over.
public nonisolated struct ExportInput: Sendable {
    public var image: CIImage
    public var recipe: EditRecipe
    public var masks: [UUID: CIImage]
    public var metadataURL: URL?

    public init(image: CIImage, recipe: EditRecipe, masks: [UUID: CIImage] = [:], metadataURL: URL? = nil) {
        self.image = image
        self.recipe = recipe
        self.masks = masks
        self.metadataURL = metadataURL
    }
}

/// Renders an export: recipe, then resizing, then encoding through ImageIO with the original's
/// metadata. Runs off the main actor; every step is a pure function of its inputs.
public nonisolated enum ExportRenderer {
    public enum ExportError: Error, LocalizedError {
        case encodingFailed(ExportFormat)
        case renderingFailed

        public var errorDescription: String? {
            switch self {
            case let .encodingFailed(format): "The image couldn't be encoded as \(format.displayName)."
            case .renderingFailed: "The image couldn't be rendered."
            }
        }
    }

    /// The edited image with its watermark and frame, at the size the settings ask for, origin at zero.
    /// `watermarkPicture` is the decoded picture of an image watermark, when there is one.
    public static func render(_ input: ExportInput, settings: ExportSettings, watermarkPicture: CIImage? = nil) async -> CIImage {
        let edited = await EditRenderer.render(image: input.image, recipe: input.recipe, masks: input.masks)
        return resize(compose(edited, settings: settings, watermarkPicture: watermarkPicture), to: settings.size)
    }

    /// Everything that changes the picture after the edit: the watermark on the photo, then the frame
    /// around it. Scale independent, so the preview can run it on a reduced image.
    public static func compose(_ edited: CIImage, settings: ExportSettings, watermarkPicture: CIImage? = nil) -> CIImage {
        FrameRenderer.apply(settings.frame, to: WatermarkRenderer.apply(settings.watermark, to: edited, picture: watermarkPicture))
    }

    /// Lanczos resampling to the requested size. Returns the image unchanged at the original size.
    public static func resize(_ image: CIImage, to size: ExportSize) -> CIImage {
        let moved = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let target = size.outputSize(for: moved.extent.size)
        guard target != moved.extent.size else { return moved }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = moved
        filter.scale = Float(target.height / moved.extent.height)
        filter.aspectRatio = Float((target.width / moved.extent.width) / (target.height / moved.extent.height))
        return (filter.outputImage ?? moved).cropped(to: CGRect(origin: .zero, size: target))
    }

    /// Full export to encoded bytes.
    public static func export(_ input: ExportInput, settings: ExportSettings, watermarkPicture: CIImage? = nil) async throws -> Data {
        let image = await render(input, settings: settings, watermarkPicture: watermarkPicture)
        return try encode(image, settings: settings, metadata: input.metadataURL.flatMap(metadata(of:)))
    }

    /// 8-bit sRGB pixels through a `CGImageDestination` of the requested type. `metadata` is merged
    /// into the file's properties.
    public static func encode(_ image: CIImage, settings: ExportSettings, metadata: [CFString: Any]? = nil) throws -> Data {
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: colorSpace)
        else { throw ExportError.renderingFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, settings.format.type.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed(settings.format)
        }
        var properties: [CFString: Any] = metadata ?? [:]
        if settings.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed(settings.format) }
        return data as Data
    }

    /// The metadata blocks worth carrying from the original to the export, with the orientation reset
    /// since the rendered pixels are already upright. Nil when the file has none or can't be read.
    public static func metadata(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let block = properties[key] {
                kept[key] = block
            }
        }
        if var tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        kept[kCGImagePropertyOrientation] = CGImagePropertyOrientation.up.rawValue
        return kept
    }
}
