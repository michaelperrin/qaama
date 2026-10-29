import CoreGraphics
import CoreImage
import EditModel

/// Applies a recipe to a small image, for thumbnails of edited photos.
public nonisolated enum ThumbnailRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false, .name: "Qaama thumbnails"])

    public static func apply(_ recipe: EditRecipe, to image: CGImage) -> CGImage? {
        guard !recipe.isIdentity else { return image }
        let output = RenderPipeline.apply(recipe, to: CIImage(cgImage: image))
        return context.createCGImage(output, from: output.extent)
    }
}
