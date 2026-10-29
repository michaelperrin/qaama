import Foundation

/// A photo in the library, independent of its source (Photos library, file on disk).
///
/// Deliberately free of PhotoKit and AppKit types so it stays portable:
/// the identifier is enough for the source to find the underlying object again.
nonisolated public struct LibraryAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let creationDate: Date?
    public let isFavorite: Bool

    public init(id: String, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, isFavorite: Bool) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.isFavorite = isFavorite
    }

    /// Width / height ratio, or 1 when the dimensions are unknown.
    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}
