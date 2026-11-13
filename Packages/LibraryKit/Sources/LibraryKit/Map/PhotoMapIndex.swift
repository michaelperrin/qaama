import Foundation
import ImageIOKit

/// The photos of one square of the map at a zoom level, shown as a single thumbnail with a count.
public nonisolated struct PhotoCluster: Identifiable, Hashable, Sendable {
    /// The level and the square: what tells a group from every other, at any zoom.
    public let cell: UInt64
    public var count: Int
    /// The mean position of its photos, where the thumbnail goes.
    public var coordinate: GeoCoordinate
    /// The most recent photo of the group, shown for all of them.
    public var coverID: LibraryAsset.ID
    /// The smallest region holding its photos, to zoom on them.
    public var bounds: GeoRegion
    /// Where its photos are in the index that made it; only meaningful to that index.
    let members: Range<Int>

    /// The photo that stands for the group, rather than its square: when zooming merges groups or
    /// splits one, the group that keeps the same photo is the same thumbnail to a view, which moves
    /// it instead of removing it and drawing another (a map would blink empty in between).
    public var id: LibraryAsset.ID {
        coverID
    }
}

/// Groups the photos of a map by squares whose size follows the zoom, so a map of tens of thousands
/// of photos only ever shows the few dozen thumbnails that fit on screen.
///
/// Positions are projected once (Web Mercator, as the map itself) onto a 2³² × 2³² grid, then sorted
/// along a Z-order curve: the photos of any square of any power-of-two subdivision of the world are
/// then neighbors in the array, and grouping at a level is one pass comparing the leading bits of
/// their code, without a dictionary or an allocation per photo. Squares are tied to the world, not to
/// the view, so dragging the map never regroups anything; changing level does.
///
/// A value: build it off the main actor (sorting 74,000 photos takes a moment in Debug) and hand it over.
public nonisolated struct PhotoMapIndex: Sendable {
    /// Squares of 2.4 m at the equator: beyond that, photos taken from the same spot stay together.
    public static let maxLevel = 24

    /// Sorted by `codes`; the three arrays run in parallel.
    private let ids: [LibraryAsset.ID]
    /// Interleaved bits of the projected position, x in the even bits.
    private let codes: [UInt64]
    /// Seconds since 1970, `Int64.min` when unknown.
    private let captureSeconds: [Int64]

    public init(_ assets: [LocatedAsset] = []) {
        var keyed = assets.map { asset in
            (code: Self.code(of: asset.coordinate),
             second: asset.captureDate.map { Int64($0.timeIntervalSince1970.rounded(.down)) } ?? .min,
             id: asset.id)
        }
        // By identifier within a spot, so the same photos always give the same index.
        keyed.sort { ($0.code, $0.id) < ($1.code, $1.id) }
        ids = keyed.map(\.id)
        codes = keyed.map(\.code)
        captureSeconds = keyed.map(\.second)
    }

    public var count: Int {
        ids.count
    }

    /// The level whose squares are the smallest ones at least `spacing` points wide on a map where
    /// the whole world is `worldWidth` points wide: groups then never sit closer than thumbnails do.
    public static func level(worldWidth: Double, spacing: Double) -> Int {
        guard worldWidth > 0, spacing > 0, worldWidth > spacing else { return 0 }
        return min(Int(log2(worldWidth / spacing).rounded(.down)), maxLevel)
    }

    /// The groups at `level` (0: the whole world in one, each level halves the squares) whose position
    /// falls in `region`, or all of them. Sorted along the curve, not by importance.
    public func clusters(level: Int, in region: GeoRegion? = nil) -> [PhotoCluster] {
        let level = min(max(level, 0), Self.maxLevel)
        let shift = UInt64(64 - 2 * level)
        let window = region.map(Window.init)
        var clusters: [PhotoCluster] = []
        codes.withUnsafeBufferPointer { codes in
            captureSeconds.withUnsafeBufferPointer { seconds in
                var start = 0
                while start < codes.count {
                    // A shift by 64 (level 0) is zero in Swift: the whole world is one square.
                    let square = codes[start] >> shift
                    var sumX: UInt64 = 0, sumY: UInt64 = 0
                    var minX = UInt32.max, maxX = UInt32.min, minY = UInt32.max, maxY = UInt32.min
                    var cover = start
                    var end = start
                    while end < codes.count, codes[end] >> shift == square {
                        let x = Self.evenBits(of: codes[end]), y = Self.evenBits(of: codes[end] >> 1)
                        sumX += UInt64(x)
                        sumY += UInt64(y)
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                        if seconds[end] > seconds[cover] {
                            cover = end
                        }
                        end += 1
                    }
                    let count = UInt64(end - start)
                    let x = UInt32(sumX / count), y = UInt32(sumY / count)
                    if window?.contains(x: x, y: y) ?? true {
                        clusters.append(PhotoCluster(
                            cell: UInt64(level) << 56 | square, count: end - start,
                            coordinate: Self.coordinate(x: x, y: y), coverID: ids[cover],
                            bounds: GeoRegion(south: Self.latitude(y: maxY), west: Self.longitude(x: minX),
                                              north: Self.latitude(y: minY), east: Self.longitude(x: maxX)),
                            members: start ..< end
                        ))
                    }
                    start = end
                }
            }
        }
        return clusters
    }

    /// The photos of a group this index made, in no order that matters: listings sort them.
    public func assetIDs(in cluster: PhotoCluster) -> [LibraryAsset.ID] {
        guard cluster.members.upperBound <= ids.count else { return [] }
        return Array(ids[cluster.members])
    }

    /// The smallest region holding every photo; nil without photos.
    public var extent: GeoRegion? {
        clusters(level: 0).first?.bounds
    }

    // MARK: - Projection

    /// A region as ranges of grid coordinates.
    private struct Window {
        var minX: UInt32, maxX: UInt32, minY: UInt32, maxY: UInt32

        init(_ region: GeoRegion) {
            minX = PhotoMapIndex.gridX(longitude: region.west)
            maxX = PhotoMapIndex.gridX(longitude: region.east)
            // The grid's y grows towards the south.
            minY = PhotoMapIndex.gridY(latitude: region.north)
            maxY = PhotoMapIndex.gridY(latitude: region.south)
        }

        func contains(x: UInt32, y: UInt32) -> Bool {
            guard y >= minY, y <= maxY else { return false }
            // Across the antimeridian the region is what lies outside the gap between east and west.
            return minX <= maxX ? x >= minX && x <= maxX : x >= minX || x <= maxX
        }
    }

    /// Web Mercator stops there: the world is then a square.
    private static let maxLatitude = 85.05112878
    private static let gridSize = 4_294_967_296.0

    private static func grid(_ fraction: Double) -> UInt32 {
        UInt32(min(max(fraction * gridSize, 0), gridSize - 1))
    }

    private static func gridX(longitude: Double) -> UInt32 {
        grid((longitude + 180) / 360)
    }

    private static func gridY(latitude: Double) -> UInt32 {
        let radians = min(max(latitude, -maxLatitude), maxLatitude) * .pi / 180
        return grid((1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2)
    }

    private static func longitude(x: UInt32) -> Double {
        Double(x) / gridSize * 360 - 180
    }

    private static func latitude(y: UInt32) -> Double {
        atan(sinh(.pi * (1 - 2 * Double(y) / gridSize))) * 180 / .pi
    }

    private static func coordinate(x: UInt32, y: UInt32) -> GeoCoordinate {
        GeoCoordinate(latitude: latitude(y: y), longitude: longitude(x: x))
    }

    private static func code(of coordinate: GeoCoordinate) -> UInt64 {
        spread(gridX(longitude: coordinate.longitude)) | spread(gridY(latitude: coordinate.latitude)) << 1
    }

    /// The 32 bits of `value` moved to the even bits of the result.
    private static func spread(_ value: UInt32) -> UInt64 {
        var bits = UInt64(value)
        bits = (bits | bits << 16) & 0x0000_FFFF_0000_FFFF
        bits = (bits | bits << 8) & 0x00FF_00FF_00FF_00FF
        bits = (bits | bits << 4) & 0x0F0F_0F0F_0F0F_0F0F
        bits = (bits | bits << 2) & 0x3333_3333_3333_3333
        bits = (bits | bits << 1) & 0x5555_5555_5555_5555
        return bits
    }

    /// The reverse of `spread`.
    private static func evenBits(of code: UInt64) -> UInt32 {
        var bits = code & 0x5555_5555_5555_5555
        bits = (bits | bits >> 1) & 0x3333_3333_3333_3333
        bits = (bits | bits >> 2) & 0x0F0F_0F0F_0F0F_0F0F
        bits = (bits | bits >> 4) & 0x00FF_00FF_00FF_00FF
        bits = (bits | bits >> 8) & 0x0000_FFFF_0000_FFFF
        bits = (bits | bits >> 16) & 0x0000_0000_FFFF_FFFF
        return UInt32(bits)
    }
}
