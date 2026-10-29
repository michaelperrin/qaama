import Foundation
import GRDB

/// A folder the user added to the library, as stored in the catalog.
public nonisolated struct CatalogFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Security-scoped bookmark, the only way back to the folder in the sandbox.
    public var bookmark: Data
    public var displayName: String
    public var lastScan: Date?

    public init(id: UUID = UUID(), bookmark: Data, displayName: String, lastScan: Date? = nil) {
        self.id = id
        self.bookmark = bookmark
        self.displayName = displayName
        self.lastScan = lastScan
    }
}

/// Pick / reject decision on a photo.
public nonisolated enum ItemFlag: Int, Codable, Sendable {
    case rejected = -1
    case none = 0
    case picked = 1
}

/// An image file known to the catalog. The `id` is Qaama's own stable identifier; everything
/// else can change when the file is renamed, moved or re-edited.
public nonisolated struct CatalogItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var folderID: UUID
    /// Path from the folder root, e.g. `Trip/DSCF0001.RAF`.
    public var relativePath: String
    public var fileName: String
    /// Uniform type identifier, e.g. `com.fuji.raw-image`.
    public var fileType: String
    public var fileSize: Int64
    public var contentModified: Date
    /// `URLResourceKey.fileResourceIdentifierKey`, serialized; survives renames on the same volume.
    public var fileIdentifier: Data?
    /// Size, date and partial hash; computed on demand to recognize copies on other volumes.
    public var fingerprint: String?
    public var isMissing: Bool
    public var missingSince: Date?

    // Image metadata, nil until the second scan phase reads the header.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var orientation: Int?
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var iso: Int?
    public var exposureTime: Double?
    public var aperture: Double?
    public var focalLength: Double?
    public var isRAW: Bool
    public var metadataRead: Date?

    // User decisions, mirrored from the sidecar.
    public var rating: Int
    public var flag: ItemFlag
    public var keywords: [String]
    public var hasEdit: Bool
    public var sidecarModified: Date?

    public var pairedItemID: UUID?

    public init(id: UUID = UUID(), folderID: UUID, relativePath: String, fileType: String, fileSize: Int64,
                contentModified: Date, fileIdentifier: Data? = nil, isRAW: Bool = false)
    {
        self.id = id
        self.folderID = folderID
        self.relativePath = relativePath
        fileName = (relativePath as NSString).lastPathComponent
        self.fileType = fileType
        self.fileSize = fileSize
        self.contentModified = contentModified
        self.fileIdentifier = fileIdentifier
        fingerprint = nil
        isMissing = false
        missingSince = nil
        self.isRAW = isRAW
        rating = 0
        flag = .none
        keywords = []
        hasEdit = false
    }

    /// True when the header must be (re)read: never read, or the file changed since.
    public var needsMetadata: Bool {
        guard let metadataRead else { return true }
        return metadataRead < contentModified
    }
}

// MARK: - GRDB mapping

nonisolated extension CatalogFolder: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folder"
}

nonisolated extension CatalogItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"

    nonisolated enum Col {
        static let id = Column(CodingKeys.id)
        static let folderID = Column(CodingKeys.folderID)
        static let relativePath = Column(CodingKeys.relativePath)
        static let fileIdentifier = Column(CodingKeys.fileIdentifier)
        static let fingerprint = Column(CodingKeys.fingerprint)
        static let isMissing = Column(CodingKeys.isMissing)
        static let captureDate = Column(CodingKeys.captureDate)
        static let contentModified = Column(CodingKeys.contentModified)
        static let metadataRead = Column(CodingKeys.metadataRead)
        static let rating = Column(CodingKeys.rating)
        static let flag = Column(CodingKeys.flag)
    }
}
