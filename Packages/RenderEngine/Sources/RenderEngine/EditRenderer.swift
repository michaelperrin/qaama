import CoreGraphics
import EditModel
import Foundation

/// Full-size rendering of an edit: decodes the original, applies the recipe, encodes a JPEG.
/// Used for exports, for the version saved into Photos, and for the cached previews.
public nonisolated enum EditRenderer {
    public enum RenderError: Error, LocalizedError {
        case noImage

        public var errorDescription: String? {
            "There is no image to render."
        }
    }

    public static func jpeg(imageURL: URL?, image: CGImage?, recipe: EditRecipe) throws -> Data {
        let source: RenderSource
        if let imageURL {
            source = .file(imageURL)
        } else if let image {
            source = .image(image)
        } else {
            throw RenderError.noImage
        }
        let loaded = try SourceImageLoader.load(source)
        return try ImageExporter.jpegData(for: RenderPipeline.apply(recipe, to: loaded.image))
    }
}
