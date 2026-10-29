import CoreGraphics
import Foundation

/// Identifies Qaama's edit recipes in Photos adjustment data and in sidecar files.
public nonisolated enum EditingFormat {
    /// Reverse-DNS identifier Photos uses to know which app can reopen an adjustment.
    public static let identifier = "fr.michaelperrin.qaama.edit"
    public static let version = "1"
    /// Suffix appended to an image file name for its sidecar, e.g. `DSCF0001.RAF.qaama`.
    public static let sidecarExtension = "qaama"

    public static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension(sidecarExtension)
    }
}

/// What the editor needs to open a photo: the original pixels and the recipe saved last time, if any.
public nonisolated struct EditingInput: Sendable {
    /// The original file when the source can expose it (RAW stays RAW).
    public let imageURL: URL?
    /// Decoded pixels when no file is available.
    public let image: CGImage?
    /// Serialized recipe saved by Qaama earlier, in `EditingFormat`.
    public let recipeData: Data?

    public init(imageURL: URL? = nil, image: CGImage? = nil, recipeData: Data? = nil) {
        self.imageURL = imageURL
        self.image = image
        self.recipeData = recipeData
    }
}

/// What the editor hands back to be stored: the recipe, and the rendered result for sources that need one.
public nonisolated struct EditingOutput: Sendable {
    public let recipeData: Data
    /// Full-size JPEG of the edit. Photos stores it next to the recipe so other apps see the result.
    public let renderedJPEG: Data
    /// True when the recipe is the identity: sources drop the edit and show the original again.
    public let isReset: Bool

    public init(recipeData: Data, renderedJPEG: Data, isReset: Bool = false) {
        self.recipeData = recipeData
        self.renderedJPEG = renderedJPEG
        self.isReset = isReset
    }
}

/// Renders the full-size JPEG of an edit from its input and recipe. Provided by the app, which owns
/// the rendering engine; sources use it to rebuild a missing preview.
public typealias PreviewRenderer = @Sendable (EditingInput, Data) async throws -> Data
