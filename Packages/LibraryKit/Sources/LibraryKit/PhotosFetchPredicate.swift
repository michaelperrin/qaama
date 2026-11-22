import Foundation
import Photos

/// Translates a `LibraryQuery` into the predicate PhotoKit applies to a listing: its native filters,
/// plus one identifier list for what it can't query: the local index's answers (RAW, JPEG twins, search,
/// place, edits) and the photos of a group picked on the map.
///
/// An identifier list keeps the listing a plain fetch result (lazy rows, native sort, album scope, change
/// tracking). Measured on 74,000 photos with 1,546 RAW: 47 ms for `IN`, 80 ms for `NOT IN`, against
/// 59 ms unfiltered; exact in each of 787 albums.
nonisolated enum PhotosFetchPredicate {
    /// `native` is what PhotoKit accepts on this system; `index` is nil when the source has no index;
    /// `indexMatches` are the assets the index found for the search text, the place and the edits filters
    /// (`PhotosIndexStore.search`), nil when neither is asked. `trash` are the photos deleted in Qaama
    /// (`PhotosTrash`): left out, or the only ones listed when `listsTrash` is true.
    /// Returns nil when the lists leave nothing to show: there is no fetch to run.
    static func make(query: LibraryQuery, native: Set<QueryCapability>, index: PhotosIndexSnapshot?, indexMatches: [String]? = nil,
                     trash: Set<String> = [], listsTrash: Bool = false) -> NSPredicate?
    {
        let filters = query.filters
        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if filters.favoritesOnly {
            predicates.append(NSPredicate(format: "isFavorite == YES"))
        }
        if let rating = filters.rating, native.contains(.rating) {
            predicates.append(NSPredicate(format: "rating \(rating.comparisonOperator) %d", rating.stars))
        }
        if let dates = filters.captureDates {
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@", dates.lowerBound as NSDate, dates.upperBound as NSDate))
        }
        // The lists are combined here, so PhotoKit gets one of them at most, and the shortest.
        var allowed = query.scopedAssetIDs
        var excluded: Set<String> = []
        if listsTrash {
            allowed = allowed?.intersection(trash) ?? trash
        } else {
            excluded = trash
        }
        if let index {
            if let indexMatches {
                allowed = allowed?.intersection(indexMatches) ?? Set(indexMatches)
            }
            if filters.rawOnly {
                // The JPEG twins aren't RAW: nothing more to exclude.
                allowed = allowed?.intersection(index.rawIDs) ?? index.rawIDs
            } else if !query.includesPairedJPEGs {
                excluded.formUnion(listsTrash ? index.twins(hiddenAmong: trash) : index.twinIDs)
            }
        }
        if !excluded.isEmpty {
            if allowed != nil {
                allowed?.subtract(excluded)
            } else {
                predicates.append(NSPredicate(format: "NOT (localIdentifier IN %@)", Array(excluded)))
            }
        }
        if let allowed {
            guard !allowed.isEmpty else { return nil }
            predicates.append(NSPredicate(format: "localIdentifier IN %@", Array(allowed)))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
}

nonisolated extension PhotosIndexSnapshot {
    /// The JPEG twins among these photos whose RAW is among them too: the pairs they show as one
    /// photo. A twin deleted alone, while the twins were being shown, stays a photo of its own.
    func twins(hiddenAmong ids: Set<String>) -> Set<String> {
        ids.filter { id in twinIDs.contains(id) && pairedIDs[id].map(ids.contains) == true }
    }
}
