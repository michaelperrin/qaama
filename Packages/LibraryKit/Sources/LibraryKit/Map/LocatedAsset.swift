import Foundation
import ImageIOKit

/// A photo with a position, whatever the source it comes from: what a map needs to know about it.
public nonisolated struct LocatedAsset: Hashable, Sendable {
    public var id: LibraryAsset.ID
    public var coordinate: GeoCoordinate
    /// Picks the photo that stands for a group: the most recent one.
    public var captureDate: Date?

    public init(id: LibraryAsset.ID, coordinate: GeoCoordinate, captureDate: Date? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.captureDate = captureDate
    }
}

/// A rectangle of the map, in degrees. `west` is greater than `east` when it spans the antimeridian.
public nonisolated struct GeoRegion: Hashable, Sendable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public var center: GeoCoordinate {
        let width = east >= west ? east - west : east - west + 360
        let longitude = west + width / 2
        return GeoCoordinate(latitude: (south + north) / 2, longitude: longitude > 180 ? longitude - 360 : longitude)
    }
}
