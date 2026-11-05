import Foundation
import ImageIOKit
import LibraryKit
import RenderEngine

/// Everything the editor needs to open a photo, gathered off the screen: what the source says about
/// it, and its pixels ready for the pipeline. Preparing takes 20 to 150 ms depending on the source,
/// so an `EditorSession` does it ahead of time for the photos next to the one on screen.
///
/// Preparing asks the source for its editing input: whoever prepares must call `endEditing` on the
/// source once the photo is no longer wanted.
public nonisolated struct PreparedPhoto: Sendable {
    public let keywords: [String]
    public let input: EditingInput
    public let sourceImage: SourceImage
    /// The file's header, read in the background: it must not hold the first frame back.
    public let metadata: Task<ImageMetadata?, Never>?

    public init(keywords: [String], input: EditingInput, sourceImage: SourceImage, metadata: Task<ImageMetadata?, Never>? = nil) {
        self.keywords = keywords
        self.input = input
        self.sourceImage = sourceImage
        self.metadata = metadata
    }

    @MainActor
    public static func prepare(_ asset: LibraryAsset, in source: any LibrarySource) async throws -> PreparedPhoto {
        let keywords = await source.keywords(for: asset)
        let input = try await source.editingInput(for: asset)
        let renderSource: RenderSource
        if let url = input.imageURL {
            renderSource = .file(url)
        } else if let image = input.image {
            renderSource = .image(image)
        } else {
            source.endEditing(asset)
            throw LibrarySourceError.editingFailed("no image data")
        }
        do {
            let sourceImage = try await Task.detached(priority: .userInitiated) { try SourceImageLoader.load(renderSource) }.value
            let metadata = input.imageURL.map { url in Task.detached { try? ImageMetadataReader.read(url) } }
            return PreparedPhoto(keywords: keywords, input: input, sourceImage: sourceImage, metadata: metadata)
        } catch {
            source.endEditing(asset)
            throw error
        }
    }
}
