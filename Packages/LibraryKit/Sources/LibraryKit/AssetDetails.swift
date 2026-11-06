import Foundation
import ImageIOKit

/// What a source can tell about a photo without opening it in the editor: the content of the
/// library's Info panel.
public nonisolated struct AssetDetails: Hashable, Sendable {
    /// The file name the photo was imported or shot under, extension included.
    public var fileName: String?
    /// What the file's header says. A source that can't reach the file fills in what it knows
    /// (dimensions, date) and leaves the camera settings empty.
    public var metadata: ImageMetadata?
    /// True when the camera settings are missing only because the original isn't on this Mac (it is
    /// in iCloud): they come once it has been downloaded, which asking for the details again with
    /// `allowingDownload` does.
    public var isOriginalInCloud: Bool

    public init(fileName: String? = nil, metadata: ImageMetadata? = nil, isOriginalInCloud: Bool = false) {
        self.fileName = fileName
        self.metadata = metadata
        self.isOriginalInCloud = isOriginalInCloud
    }

    /// What the listing alone knows, to show at once while the source reads the rest.
    public init(_ asset: LibraryAsset) {
        self.init(metadata: asset.pixelWidth > 0 && asset.pixelHeight > 0
            ? ImageMetadata(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, captureDate: asset.creationDate)
            : nil)
    }
}
