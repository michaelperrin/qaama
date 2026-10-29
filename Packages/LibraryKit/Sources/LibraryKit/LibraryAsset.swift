import Foundation

/// A photo in the library, independent of its source (Photos library, file on disk).
///
/// Deliberately free of PhotoKit and AppKit types so it stays portable:
/// the identifier is enough for the source to find the underlying object again.
public nonisolated struct LibraryAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let creationDate: Date?
    public let isFavorite: Bool
    /// Star rating from 0 (unrated) to 5, stored natively by Photos.
    public let rating: Int

    public init(id: String, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, isFavorite: Bool, rating: Int = 0) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.rating = min(max(rating, 0), 5)
    }

    /// Width / height ratio, or 1 when the dimensions are unknown.
    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}
