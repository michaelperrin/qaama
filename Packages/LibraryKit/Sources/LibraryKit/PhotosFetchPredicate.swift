import Foundation
import Photos

/// Translates a `LibraryQuery` into the predicate PhotoKit applies to a listing: its native filters,
/// plus one identifier list for what it can't query: the local index's answers (RAW, JPEG twins, search)
/// and the photos of a group picked on the map.
///
/// An identifier list keeps the listing a plain fetch result (lazy rows, native sort, album scope, change
/// tracking). Measured on 74,000 photos with 1,546 RAW: 47 ms for `IN`, 80 ms for `NOT IN`, against
/// 59 ms unfiltered; exact in each of 787 albums.
nonisolated enum PhotosFetchPredicate {
    /// `native` is what PhotoKit accepts on this system; `index` is nil when the source has no index;
    /// `searchMatches` are the assets found for the search text, nil when nothing is searched.
    /// Returns nil when the lists leave nothing to show: there is no fetch to run.
    static func make(query: LibraryQuery, native: Set<QueryCapability>, index: PhotosIndexSnapshot?, searchMatches: [String]? = nil) -> NSPredicate? {
        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if query.favoritesOnly {
            predicates.append(NSPredicate(format: "isFavorite == YES"))
        }
        if query.minimumRating > 0, native.contains(.rating) {
            predicates.append(NSPredicate(format: "rating >= %d", query.minimumRating))
        }
        // The lists are combined here, so PhotoKit gets one of them at most, and the shortest.
        var allowed = query.onlyAssetIDs
        if let index {
            if let searchMatches {
                allowed = allowed?.intersection(searchMatches) ?? Set(searchMatches)
            }
            if query.rawOnly {
                // The JPEG twins aren't RAW: nothing more to exclude.
                allowed = allowed?.intersection(index.rawIDs) ?? index.rawIDs
            } else if !query.includesPairedJPEGs, !index.twinIDs.isEmpty {
                if allowed != nil {
                    allowed?.subtract(index.twinIDs)
                } else {
                    predicates.append(NSPredicate(format: "NOT (localIdentifier IN %@)", Array(index.twinIDs)))
                }
            }
        }
        if let allowed {
            guard !allowed.isEmpty else { return nil }
            predicates.append(NSPredicate(format: "localIdentifier IN %@", Array(allowed)))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
}
