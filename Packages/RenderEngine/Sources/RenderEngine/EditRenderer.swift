import CoreGraphics
import CoreImage
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

    /// `masks` are precomputed model masks by component id; missing ones are resolved here.
    public static func jpeg(imageURL: URL?, image: CGImage?, recipe: EditRecipe, masks: [UUID: CIImage] = [:]) async throws -> Data {
        let source: RenderSource
        if let imageURL {
            source = .file(imageURL)
        } else if let image {
            source = .image(image)
        } else {
            throw RenderError.noImage
        }
        let loaded = try SourceImageLoader.load(source)
        let reference = recipe.geometry.map { GeometryRenderer.straighten(loaded.image, with: $0) } ?? loaded.image
        let resolved = await ModelMasks.resolveAll(in: recipe, reference: reference, existing: masks)
        return try ImageExporter.jpegData(for: RenderPipeline.apply(recipe, to: loaded.image, geometry: recipe.geometry, masks: resolved))
    }
}
