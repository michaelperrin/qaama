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
    /// Last time the photo or its edit changed; part of the identity of a cached thumbnail.
    public let modificationDate: Date?
    /// Whether a non-destructive edit is stored for this photo.
    public let hasEdit: Bool

    public init(id: String, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, isFavorite: Bool, rating: Int = 0,
                modificationDate: Date? = nil, hasEdit: Bool = false)
    {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.rating = min(max(rating, 0), 5)
        self.modificationDate = modificationDate
        self.hasEdit = hasEdit
    }

    /// Copy with a new rating.
    public func withRating(_ rating: Int) -> LibraryAsset {
        LibraryAsset(id: id, pixelWidth: pixelWidth, pixelHeight: pixelHeight, creationDate: creationDate, isFavorite: isFavorite,
                     rating: rating, modificationDate: modificationDate, hasEdit: hasEdit)
    }

    /// Copy marked as edited (or not) at the given date.
    public func withEdit(_ hasEdit: Bool, at date: Date) -> LibraryAsset {
        LibraryAsset(id: id, pixelWidth: pixelWidth, pixelHeight: pixelHeight, creationDate: creationDate, isFavorite: isFavorite,
                     rating: rating, modificationDate: date, hasEdit: hasEdit)
    }

    /// Width / height ratio, or 1 when the dimensions are unknown.
    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}
