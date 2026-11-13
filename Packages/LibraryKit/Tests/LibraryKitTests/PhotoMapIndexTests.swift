import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

struct PhotoMapIndexTests {
    private static let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
    private static let versailles = GeoCoordinate(latitude: 48.8049, longitude: 2.1204)
    private static let lyon = GeoCoordinate(latitude: 45.7640, longitude: 4.8357)
    private static let sydney = GeoCoordinate(latitude: -33.8688, longitude: 151.2093)

    private func photo(_ id: String, _ place: GeoCoordinate, at second: TimeInterval? = nil) -> LocatedAsset {
        LocatedAsset(id: id, coordinate: place, captureDate: second.map { Date(timeIntervalSince1970: $0) })
    }

    private func isClose(_ a: GeoCoordinate, _ b: GeoCoordinate, within degrees: Double = 0.0001) -> Bool {
        abs(a.latitude - b.latitude) < degrees && abs(a.longitude - b.longitude) < degrees
    }

    @Test func theWholeWorldIsOneGroupAtLevelZero() {
        let index = PhotoMapIndex([photo("a", Self.paris), photo("b", Self.sydney), photo("c", Self.lyon)])

        let clusters = index.clusters(level: 0)
        #expect(clusters.map(\.count) == [3])
        #expect(PhotoMapIndex().clusters(level: 0).isEmpty)
    }

    @Test func zoomingInSplitsGroupsWithoutLosingAPhoto() {
        let index = PhotoMapIndex([
            photo("paris-1", Self.paris), photo("paris-2", Self.paris), photo("versailles", Self.versailles),
            photo("lyon", Self.lyon), photo("sydney", Self.sydney),
        ])

        // Squares of 1,250 km at level 5: France in one group, Australia in another.
        #expect(index.clusters(level: 5).map(\.count).sorted() == [1, 4])
        // 39 km at level 10: Paris and Versailles (17 km apart) share a square, Lyon has its own.
        #expect(index.clusters(level: 10).map(\.count).sorted() == [1, 1, 3])
        // 2.4 km at level 14: only the two photos taken at the same spot stay together.
        #expect(index.clusters(level: 14).map(\.count).sorted() == [1, 1, 1, 2])
        for level in 0 ... PhotoMapIndex.maxLevel {
            #expect(index.clusters(level: level).reduce(0) { $0 + $1.count } == 5)
        }
        // Levels out of range are clamped rather than trapping on the shift.
        #expect(index.clusters(level: 99) == index.clusters(level: PhotoMapIndex.maxLevel))
        #expect(index.clusters(level: -1).map(\.count) == [5])
    }

    @Test func aGroupSitsAtTheMeanPositionOfItsPhotos() throws {
        let west = GeoCoordinate(latitude: 48.85, longitude: 2.30), east = GeoCoordinate(latitude: 48.85, longitude: 2.34)
        let index = PhotoMapIndex([photo("a", west), photo("b", east), photo("c", east), photo("d", east)])

        let cluster = try #require(index.clusters(level: 10).first)
        #expect(cluster.count == 4)
        #expect(isClose(cluster.coordinate, GeoCoordinate(latitude: 48.85, longitude: 2.33)))
        #expect(isClose(GeoCoordinate(latitude: cluster.bounds.south, longitude: cluster.bounds.west), west))
        #expect(isClose(GeoCoordinate(latitude: cluster.bounds.north, longitude: cluster.bounds.east), east))
    }

    @Test func theMostRecentPhotoStandsForItsGroup() throws {
        let index = PhotoMapIndex([
            photo("undated", Self.paris), photo("old", Self.paris, at: 100), photo("new", Self.paris, at: 300),
            photo("middle", Self.paris, at: 200),
        ])

        let cluster = try #require(index.clusters(level: 12).first)
        #expect(cluster.coverID == "new")
        #expect(index.assetIDs(in: cluster).sorted() == ["middle", "new", "old", "undated"])
    }

    @Test func onlyTheGroupsOfTheRegionAreReturned() {
        let index = PhotoMapIndex([photo("paris", Self.paris), photo("lyon", Self.lyon), photo("sydney", Self.sydney)])
        let france = GeoRegion(south: 42, west: -5, north: 51, east: 8)
        let northOfFrance = GeoRegion(south: 48, west: -5, north: 51, east: 8)

        #expect(index.clusters(level: 10, in: france).map(\.coverID).sorted() == ["lyon", "paris"])
        #expect(index.clusters(level: 10, in: northOfFrance).map(\.coverID) == ["paris"])
        // A group is in or out by its own position (here between Paris and Lyon), not by its photos'.
        #expect(index.clusters(level: 5, in: northOfFrance).isEmpty)
    }

    @Test func aRegionCanSpanTheAntimeridian() {
        let fiji = GeoCoordinate(latitude: -17.7, longitude: 178.0), samoa = GeoCoordinate(latitude: -13.8, longitude: -172.1)
        let index = PhotoMapIndex([photo("fiji", fiji), photo("samoa", samoa), photo("paris", Self.paris)])
        let pacific = GeoRegion(south: -30, west: 170, north: 0, east: -165)

        #expect(index.clusters(level: 10, in: pacific).map(\.coverID).sorted() == ["fiji", "samoa"])
        #expect(isClose(pacific.center, GeoCoordinate(latitude: -15, longitude: -177.5)))
    }

    @Test func aGroupIsTheSameSquareAcrossRegionsAndAnotherAcrossLevels() throws {
        let index = PhotoMapIndex([photo("paris", Self.paris), photo("lyon", Self.lyon)])
        let everywhere = try #require(index.clusters(level: 10).first { $0.coverID == "paris" })
        let nearby = try #require(index.clusters(level: 10, in: GeoRegion(south: 48, west: 2, north: 49, east: 3)).first)

        #expect(everywhere.cell == nearby.cell)
        #expect(index.clusters(level: 11).allSatisfy { $0.cell != everywhere.cell })
    }

    @Test func theGroupKeepingItsPhotoKeepsItsIdentityWhenZoomingMergesOrSplits() throws {
        let index = PhotoMapIndex([
            photo("paris", Self.paris, at: 300), photo("versailles", Self.versailles, at: 200), photo("lyon", Self.lyon, at: 100),
        ])
        let merged = try #require(index.clusters(level: 5).first)
        let split = index.clusters(level: 14)

        // One thumbnail for France, three once zoomed in: the one showing Paris is the same throughout.
        #expect(merged.count == 3 && merged.id == "paris")
        #expect(split.map(\.id).sorted() == ["lyon", "paris", "versailles"])
        #expect(split.first { $0.id == merged.id }?.cell != merged.cell)
    }

    @Test func polesAndTheEdgesOfTheWorldAreClampedToTheGrid() {
        let index = PhotoMapIndex([
            photo("north", GeoCoordinate(latitude: 90, longitude: 0)), photo("south", GeoCoordinate(latitude: -90, longitude: 0)),
            photo("east", GeoCoordinate(latitude: 0, longitude: 180)), photo("west", GeoCoordinate(latitude: 0, longitude: -180)),
        ])

        #expect(index.clusters(level: 3).reduce(0) { $0 + $1.count } == 4)
        #expect(index.clusters(level: 3).allSatisfy { abs($0.coordinate.latitude) <= 85.06 && abs($0.coordinate.longitude) <= 180 })
    }

    @Test func theLevelFollowsTheZoomOfTheMap() {
        // The world 1,024 points wide, a thumbnail every 100: squares of 128 points at level 3.
        #expect(PhotoMapIndex.level(worldWidth: 1024, spacing: 100) == 3)
        #expect(PhotoMapIndex.level(worldWidth: 1600, spacing: 100) == 4)
        #expect(PhotoMapIndex.level(worldWidth: 80, spacing: 100) == 0)
        #expect(PhotoMapIndex.level(worldWidth: 0, spacing: 100) == 0)
        #expect(PhotoMapIndex.level(worldWidth: 1e30, spacing: 100) == PhotoMapIndex.maxLevel)
    }
}
