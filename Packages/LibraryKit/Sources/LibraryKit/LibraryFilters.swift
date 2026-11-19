import Foundation
import ImageIOKit

/// What a photo must be to be listed: the filters of a `LibraryQuery`. Nil or false asks nothing.
/// Sources apply the ones they support (see `LibrarySource.queryCapabilities`) and ignore the rest.
public nonisolated struct LibraryFilters: Hashable, Sendable {
    public var rating: RatingFilter?
    public var flag: FlagFilter?
    /// Photos with an edit, or without one.
    public var edits: EditsFilter?
    public var rawOnly = false
    /// Photos' hearts.
    public var favoritesOnly = false
    /// Photos taken from the lower bound up to, but not at, the upper one. A photo that says no
    /// capture date isn't listed.
    public var captureDates: Range<Date>?
    /// Photos taken within a distance of a place. A photo without a location isn't listed.
    public var place: PlaceFilter?

    public init() {}

    /// True when nothing is asked.
    public var isEmpty: Bool {
        self == LibraryFilters()
    }

    /// In-memory evaluation, for sources that hold their assets in an array (and for tests).
    public func matches(_ asset: LibraryAsset, isRAW: Bool = false) -> Bool {
        if let rating, !rating.matches(asset.rating) {
            return false
        }
        if let flag, !flag.matches(asset.flag) {
            return false
        }
        if let edits, !edits.matches(hasEdit: asset.hasEdit) {
            return false
        }
        if rawOnly, !isRAW {
            return false
        }
        if favoritesOnly, !asset.isFavorite {
            return false
        }
        if let captureDates {
            guard let date = asset.creationDate, captureDates.contains(date) else { return false }
        }
        if let place {
            guard let location = asset.location, place.contains(location) else { return false }
        }
        return true
    }
}

/// A number of stars and how a photo's rating must compare to it. The comparisons include the
/// number itself: "at least 5 stars" lists the five-star photos, where "more than 5" listed none.
public nonisolated struct RatingFilter: Hashable, Codable, Sendable {
    public enum Comparison: String, CaseIterable, Codable, Sendable {
        case atLeast
        case atMost
        case exactly
    }

    public var comparison: Comparison
    /// 0 to 5; 0 is an unrated photo, so "exactly 0" lists the photos still to rate.
    public var stars: Int

    public init(_ comparison: Comparison, _ stars: Int) {
        self.comparison = comparison
        self.stars = stars
    }

    public static func atLeast(_ stars: Int) -> RatingFilter {
        RatingFilter(.atLeast, stars)
    }

    public func matches(_ rating: Int) -> Bool {
        switch comparison {
        case .atLeast: rating >= stars
        case .atMost: rating <= stars
        case .exactly: rating == stars
        }
    }

    /// The comparison as SQLite and `NSPredicate` both write it.
    var comparisonOperator: String {
        switch comparison {
        case .atLeast: ">="
        case .atMost: "<="
        case .exactly: "="
        }
    }
}

/// Whether a photo must have been edited to be listed. In a folder an edit is Qaama's, saved next
/// to the image; in the Photos library it is any app's, as Photos tells them all the same way.
public nonisolated enum EditsFilter: String, CaseIterable, Codable, Sendable {
    case edited
    case notEdited

    public func matches(hasEdit: Bool) -> Bool {
        (self == .edited) == hasEdit
    }
}

/// Which flags a photo may carry to be listed.
public nonisolated enum FlagFilter: String, CaseIterable, Codable, Sendable {
    case picked
    case rejected
    case unflagged
    /// Everything but the rejects: the usual culling view.
    case notRejected

    public func matches(_ flag: ItemFlag) -> Bool {
        switch self {
        case .picked: flag == .picked
        case .rejected: flag == .rejected
        case .unflagged: flag == .none
        case .notRejected: flag != .rejected
        }
    }
}

/// A disc on the globe: the photos taken within `radius` of `center`.
public nonisolated struct PlaceFilter: Hashable, Sendable {
    public var center: GeoCoordinate
    /// In meters, along the ground.
    public var radius: Double

    /// The mean radius of the Earth, in meters: distances are measured on a sphere, which is off by
    /// a few tenths of a percent at most.
    static let earthRadius = 6_371_008.8

    public init(center: GeoCoordinate, radius: Double) {
        self.center = center
        self.radius = radius
    }

    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        Self.distance(from: center, to: coordinate) <= radius
    }

    /// The distance between two places along a great circle (haversine formula), in meters.
    public static func distance(from one: GeoCoordinate, to other: GeoCoordinate) -> Double {
        let latitude1 = one.latitude * .pi / 180, latitude2 = other.latitude * .pi / 180
        let deltaLatitude = latitude2 - latitude1
        let deltaLongitude = (other.longitude - one.longitude) * .pi / 180
        let haversine = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return 2 * earthRadius * asin(min(1, haversine.squareRoot()))
    }

    /// The parallels and meridians that box the disc in, in degrees: what a database can compare
    /// columns to before `contains` decides. `longitudes` holds two ranges when the disc spans the
    /// antimeridian, and is nil when it reaches a pole or goes around the globe: every meridian
    /// crosses it.
    var bounds: (latitudes: ClosedRange<Double>, longitudes: [ClosedRange<Double>]?) {
        let angle = radius / Self.earthRadius
        let span = angle * 180 / .pi
        let south = center.latitude - span, north = center.latitude + span
        let latitudes = max(south, -90) ... min(north, 90)
        guard south > -90, north < 90, angle < .pi / 2 else { return (latitudes, nil) }
        // The disc is widest in longitude nearer the pole than its center.
        let halfWidth = asin(min(1, sin(angle) / cos(center.latitude * .pi / 180))) * 180 / .pi
        let west = center.longitude - halfWidth, east = center.longitude + halfWidth
        if west < -180 {
            return (latitudes, [west + 360 ... 180, -180 ... east])
        }
        if east > 180 {
            return (latitudes, [west ... 180, -180 ... east - 360])
        }
        return (latitudes, [west ... east])
    }

    /// The box of `bounds` as an SQL condition on two columns (or expressions) holding degrees,
    /// with the values to bind. A null position never passes.
    func boxCondition(latitude: String, longitude: String) -> (sql: String, arguments: [Double]) {
        let bounds = bounds
        var sql = "\(latitude) BETWEEN ? AND ?"
        var arguments = [bounds.latitudes.lowerBound, bounds.latitudes.upperBound]
        if let longitudes = bounds.longitudes {
            sql += " AND (" + longitudes.map { _ in "\(longitude) BETWEEN ? AND ?" }.joined(separator: " OR ") + ")"
            arguments += longitudes.flatMap { [$0.lowerBound, $0.upperBound] }
        } else {
            sql += " AND \(longitude) IS NOT NULL"
        }
        return ("(\(sql))", arguments)
    }
}
