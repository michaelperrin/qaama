import Foundation
import Photos

/// Reads a fetch result in slices: objects are faulted and released slice by slice, to keep memory
/// flat on large libraries, and reading rows in order is what PhotoKit does fast (0.02 ms per asset,
/// against 2.8 ms for scattered rows).
nonisolated enum PhotosFetchEnumeration {
    private static let sliceSize = 2000

    /// Calls `body` for the assets at `rows` (all of them by default), in order. With
    /// `stoppingWhenCancelled`, gives up between two slices once the task is cancelled and returns
    /// false: what was read is then incomplete and must not be taken for the whole.
    @discardableResult
    static func forEachAsset(in result: PHFetchResult<PHAsset>, rows: Range<Int>? = nil, stoppingWhenCancelled: Bool = false,
                             _ body: (PHAsset) -> Void) -> Bool
    {
        let rows = (rows ?? 0 ..< result.count).clamped(to: 0 ..< result.count)
        for start in stride(from: rows.lowerBound, to: rows.upperBound, by: sliceSize) {
            if stoppingWhenCancelled, Task.isCancelled {
                return false
            }
            autoreleasepool {
                result.objects(at: IndexSet(integersIn: start ..< min(start + sliceSize, rows.upperBound))).forEach(body)
            }
        }
        return true
    }
}

/// The months of a listing of the Photos library, read from the dates of its fetch result. PhotoKit
/// has no query for "how many photos per month": the dates are read row by row, which stays exact
/// whatever the listing is (an album, favorites, a search).
nonisolated enum PhotosTimeline {
    /// Rows read at once when a listing is shown, on the main actor: more than a screen of the
    /// smallest thumbnails, for about 20 ms.
    static let firstRows = 1000

    /// The months of the first rows, the others pending: what the grid shows while `complete` runs.
    static func firstRows(of result: PHFetchResult<PHAsset>, calendar: Calendar = .current) -> DateTimeline {
        var builder = DateTimeline.Builder(calendar: calendar)
        PhotosFetchEnumeration.forEachAsset(in: result, rows: 0 ..< firstRows) { builder.append($0.creationDate) }
        return builder.timeline(pendingUpTo: result.count)
    }

    /// The months of every row; nil when the task was cancelled on the way. Off the main actor: a
    /// second or two for a large library.
    static func complete(for result: PHFetchResult<PHAsset>, calendar: Calendar = .current) -> DateTimeline? {
        var builder = DateTimeline.Builder(calendar: calendar)
        guard PhotosFetchEnumeration.forEachAsset(in: result, stoppingWhenCancelled: true, { builder.append($0.creationDate) }) else {
            return nil
        }
        return builder.timeline
    }
}
