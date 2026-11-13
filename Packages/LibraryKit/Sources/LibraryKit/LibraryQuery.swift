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
    /// Restricts a folder source to one of its subdirectories (relative path); nil means the whole folder.
    /// A scope, not a filter: `isUnfiltered` ignores it and "clear filters" keeps it.
    public var folderPath: String?
    /// RAW + JPEG pairs show as one photo (the RAW) unless the JPEG twins are asked for. Not a filter.
    public var includesPairedJPEGs = false
    /// Restricts the listing to these photos: a group picked on the map. A scope like `folderPath`,
    /// not a filter. The sources that put their photos on a map (`LibrarySource.hasPlaces`) honor it.
    public var onlyAssetIDs: Set<LibraryAsset.ID>?

    public init() {}

    public static let `default` = LibraryQuery()

    /// True when no filter is active (sorting doesn't count).
    public var isUnfiltered: Bool {
        minimumRating == 0 && flag == .any && !editedOnly && !rawOnly && !favoritesOnly
            && searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The same listing without its filters: the sort and the scopes stay.
    public var clearingFilters: LibraryQuery {
        var cleared = LibraryQuery()
        cleared.sort = sort
        cleared.ascending = ascending
        cleared.folderPath = folderPath
        cleared.includesPairedJPEGs = includesPairedJPEGs
        cleared.onlyAssetIDs = onlyAssetIDs
        return cleared
    }

    /// In-memory evaluation, for sources that hold their assets in an array (and for tests).
    public func matches(_ asset: LibraryAsset, isRAW: Bool = false) -> Bool {
        if let onlyAssetIDs, !onlyAssetIDs.contains(asset.id) {
            return false
        }
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
        // These sources have no file name: the identifier stands in for it.
        return SearchText.matches(searchText, in: asset.keywords + [asset.id])
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
    /// RAW + JPEG pairs exist as two photos here, so the JPEG twins can be hidden or shown.
    case pairedJPEGs
    case favorite
    case search
}
