import Foundation

/// How a source sorts and filters its photos. Sources apply what they support (see
/// `LibrarySource.queryCapabilities`) and ignore the rest.
public nonisolated struct LibraryQuery: Hashable, Sendable {
    public enum Sort: String, CaseIterable, Sendable {
        case captureDate
        case modificationDate
        case rating
        case fileName
    }

    public enum FlagFilter: String, CaseIterable, Sendable {
        case any
        case picked
        case rejected
        case unflagged
        /// Everything but the rejects: the usual culling view.
        case notRejected
    }

    public var sort: Sort = .captureDate
    /// Newest first by default; file names sort ascending by default when chosen.
    public var ascending = false
    /// 0 keeps unrated photos; 3 keeps three stars and up.
    public var minimumRating = 0
    public var flag: FlagFilter = .any
    public var editedOnly = false
    public var rawOnly = false
    /// Photos' hearts.
    public var favoritesOnly = false
    /// Matches file names and keywords.
    public var searchText = ""

    public init() {}

    public static let `default` = LibraryQuery()

    /// True when no filter is active (sorting doesn't count).
    public var isUnfiltered: Bool {
        minimumRating == 0 && flag == .any && !editedOnly && !rawOnly && !favoritesOnly
            && searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// In-memory evaluation, for sources that hold their assets in an array (and for tests).
    public func matches(_ asset: LibraryAsset, isRAW: Bool = false) -> Bool {
        if asset.rating < minimumRating {
            return false
        }
        switch flag {
        case .any: break
        case .picked where asset.flag != .picked: return false
        case .rejected where asset.flag != .rejected: return false
        case .unflagged where asset.flag != .none: return false
        case .notRejected where asset.flag == .rejected: return false
        default: break
        }
        if editedOnly, !asset.hasEdit {
            return false
        }
        if rawOnly, !isRAW {
            return false
        }
        if favoritesOnly, !asset.isFavorite {
            return false
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            let haystack = (asset.keywords + [asset.id]).joined(separator: " ")
            if haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
        }
        return true
    }

    /// In-memory ordering, for the same sources.
    public func areInIncreasingOrder(_ lhs: LibraryAsset, _ rhs: LibraryAsset) -> Bool {
        let result: Bool = switch sort {
        case .captureDate: (lhs.creationDate ?? .distantPast) < (rhs.creationDate ?? .distantPast)
        case .modificationDate: (lhs.modificationDate ?? .distantPast) < (rhs.modificationDate ?? .distantPast)
        case .rating: lhs.rating < rhs.rating
        case .fileName: lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        return ascending ? result : !result
    }
}

/// Which parts of a `LibraryQuery` a source honors.
public nonisolated enum QueryCapability: Sendable, Hashable {
    case sortByRating
    case sortByFileName
    case rating
    case flag
    case edited
    case raw
    case favorite
    case search
}
