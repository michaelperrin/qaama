import Foundation

/// A photo in the library, independent of its source (Photos library, file on disk).
///
/// Deliberately free of PhotoKit and AppKit types so it stays portable:
/// the identifier is enough for the source to find the underlying object again.
public nonisolated struct LibraryAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var creationDate: Date?
    /// Photos' heart; folders don't have one.
    public var isFavorite: Bool
    /// Star rating from 0 (unrated) to 5.
    public var rating: Int {
        didSet { rating = min(max(rating, 0), 5) }
    }

    /// Pick / reject decision.
    public var flag: ItemFlag
    public var keywords: [String]
    /// Last time the photo or its edit changed; part of the identity of a cached thumbnail.
    public var modificationDate: Date?
    /// Whether a non-destructive edit is stored for this photo.
    public var hasEdit: Bool
    public var isRAW: Bool
    /// The other half of a RAW + JPEG pair shot together, when the source pairs them.
    public var pairedAssetID: String?

    public init(id: String, pixelWidth: Int, pixelHeight: Int, creationDate: Date?, isFavorite: Bool, rating: Int = 0,
                flag: ItemFlag = .none, keywords: [String] = [], modificationDate: Date? = nil, hasEdit: Bool = false,
                isRAW: Bool = false, pairedAssetID: String? = nil)
    {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.keywords = keywords
        self.modificationDate = modificationDate
        self.hasEdit = hasEdit
        self.isRAW = isRAW
        self.pairedAssetID = pairedAssetID
    }

    /// Width / height ratio, or 1 when the dimensions are unknown.
    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}
