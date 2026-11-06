import Foundation
import Photos

/// Everything a listing of the Photos library depends on, as values: the fetch can then run off the main
/// actor. It must for a search, whose identifier list makes PhotoKit slower as it grows (measured: 40 ms
/// for a few matches, 100 ms for 15,000, 200 ms for 52,000 of 74,000 photos).
nonisolated struct PhotosListing: Sendable {
    var query: LibraryQuery
    /// The native filters and sorts PhotoKit accepts on this system.
    var native: Set<QueryCapability>
    /// The index answers to filter with; nil when the source has no index.
    var index: PhotosIndexSnapshot?
    /// The assets found for the search text; nil when nothing is searched.
    var searchMatches: [String]?
    /// Local identifier of the album to list; nil for the whole library.
    var albumID: String?

    func fetch() -> PHFetchResult<PHAsset> {
        // Nothing can match (no RAW, no search result): an empty identifier list is a predicate PhotoKit
        // has no reason to accept, so ask for no asset instead.
        guard let predicate = PhotosFetchPredicate.make(query: query, native: native, index: index, searchMatches: searchMatches) else {
            return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
        }
        let options = PHFetchOptions()
        options.sortDescriptors = sortDescriptors
        options.predicate = predicate
        if let albumID, let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            return PHAsset.fetchAssets(in: collection, options: options)
        }
        return PHAsset.fetchAssets(with: options)
    }

    /// The query's sort in PhotoKit's terms.
    private var sortDescriptors: [NSSortDescriptor] {
        switch query.sort {
        case .rating where native.contains(.sortByRating):
            [NSSortDescriptor(key: "rating", ascending: query.ascending), NSSortDescriptor(key: "creationDate", ascending: false)]
        case .modificationDate:
            [NSSortDescriptor(key: "modificationDate", ascending: query.ascending)]
        default:
            [NSSortDescriptor(key: "creationDate", ascending: query.ascending)]
        }
    }
}
