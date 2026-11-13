import Foundation

/// The rows of several listings, each sorted by date, woven into one listing sorted the same way:
/// which row of which listing comes at each place, and back.
///
/// Built once per change of a listing, off the main actor (a pass over every row; the listings of a
/// whole photo library take tens of milliseconds); answering for a row is then an array access.
nonisolated struct ListingMerge: Sendable {
    /// A row of one of the listings.
    struct Entry: Hashable, Sendable {
        var listing: Int32
        var row: Int32
    }

    /// The merged listing, in order.
    private(set) var entries: [Entry] = []
    /// For each listing, where each of its rows went.
    private var positions: [[Int32]] = []
    /// The months of the merged listing.
    private(set) var timeline = DateTimeline(dates: [])

    init() {}

    /// `dates` holds, per listing, the date of each row in the listing's own order: newest first,
    /// or oldest first when `ascending`. Rows without a date are expected last and stay last.
    ///
    /// A listing isn't trusted to be perfectly sorted (a source may list a photo without a capture
    /// date by another date): a row out of order stays where its listing put it, next to its
    /// neighbors, rather than being pulled elsewhere in the merge.
    init(dates: [[Date?]], ascending: Bool, calendar: Calendar = .current) {
        let keys = dates.map { Self.keys(for: $0, ascending: ascending) }
        let total = dates.reduce(0) { $0 + $1.count }
        var heads = [Int](repeating: 0, count: dates.count)
        var builder = DateTimeline.Builder(calendar: calendar)
        entries.reserveCapacity(total)
        positions = dates.map { [Int32](repeating: 0, count: $0.count) }
        for place in 0 ..< total {
            var best = -1
            for listing in keys.indices where heads[listing] < keys[listing].count {
                // On equal dates the first listing goes first: the order never depends on chance.
                if best < 0 || Self.comes(keys[listing][heads[listing]], before: keys[best][heads[best]], ascending: ascending) {
                    best = listing
                }
            }
            let row = heads[best]
            entries.append(Entry(listing: Int32(best), row: Int32(row)))
            positions[best][row] = Int32(place)
            builder.append(dates[best][row])
            heads[best] += 1
        }
        timeline = builder.timeline
    }

    /// Where a row of a listing is in the merged one; nil when the listing has since changed.
    func position(listing: Int, row: Int) -> Int? {
        guard positions.indices.contains(listing), positions[listing].indices.contains(row) else { return nil }
        return Int(positions[listing][row])
    }

    private static func comes(_ lhs: Double, before rhs: Double, ascending: Bool) -> Bool {
        ascending ? lhs < rhs : lhs > rhs
    }

    /// The dates as numbers that never go back on the listing's order: a row out of order takes the
    /// date of the row before it, and rows without a date count as the far end.
    private static func keys(for dates: [Date?], ascending: Bool) -> [Double] {
        var keys: [Double] = []
        keys.reserveCapacity(dates.count)
        var last = ascending ? -Double.infinity : Double.infinity
        for date in dates {
            let own = date?.timeIntervalSinceReferenceDate ?? (ascending ? Double.infinity : -Double.infinity)
            last = ascending ? max(last, own) : min(last, own)
            keys.append(last)
        }
        return keys
    }
}
