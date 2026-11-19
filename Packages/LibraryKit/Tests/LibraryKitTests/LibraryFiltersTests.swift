import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

struct LibraryFiltersTests {
    private let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
    private let versailles = GeoCoordinate(latitude: 48.8049, longitude: 2.1204)
    private let lyon = GeoCoordinate(latitude: 45.7640, longitude: 4.8357)

    private func asset(_ id: String, rating: Int = 0, date: TimeInterval? = 0, location: GeoCoordinate? = nil) -> LibraryAsset {
        LibraryAsset(id: id, pixelWidth: 1, pixelHeight: 1, creationDate: date.map { Date(timeIntervalSince1970: $0) }, isFavorite: false,
                     rating: rating, location: location)
    }

    @Test func ratingComparisonsIncludeTheNumberItself() {
        #expect((0 ... 5).filter(RatingFilter(.atLeast, 3).matches) == [3, 4, 5])
        #expect((0 ... 5).filter(RatingFilter(.atMost, 3).matches) == [0, 1, 2, 3])
        #expect((0 ... 5).filter(RatingFilter(.exactly, 3).matches) == [3])
        // The photos still to rate.
        #expect((0 ... 5).filter(RatingFilter(.exactly, 0).matches) == [0])
    }

    @Test func datesKeepTheLowerBoundAndLeaveOutTheUpperOne() {
        var filters = LibraryFilters()
        filters.captureDates = Date(timeIntervalSince1970: 100) ..< Date(timeIntervalSince1970: 200)
        #expect(!filters.isEmpty)
        #expect(filters.matches(asset("a", date: 100)) && filters.matches(asset("b", date: 199)))
        #expect(!filters.matches(asset("c", date: 99)) && !filters.matches(asset("d", date: 200)))
        #expect(!filters.matches(asset("e", date: nil)), "a photo without a date isn't within any dates")
    }

    @Test func aPlaceKeepsThePhotosTakenWithinItsRadius() {
        // Paris to Lyon is 392 km as the crow flies, Paris to Versailles 18 km.
        let toLyon = PlaceFilter.distance(from: paris, to: lyon)
        #expect(abs(toLyon - 392_000) < 2000)
        var filters = LibraryFilters()
        filters.place = PlaceFilter(center: paris, radius: 25000)
        #expect(filters.matches(asset("a", location: paris)) && filters.matches(asset("b", location: versailles)))
        #expect(!filters.matches(asset("c", location: lyon)))
        #expect(!filters.matches(asset("d")), "a photo without a location is nowhere")
        filters.place?.radius = 400_000
        #expect(filters.matches(asset("c", location: lyon)))
    }

    @Test func theBoxAroundAPlaceHoldsItsDisc() {
        let place = PlaceFilter(center: paris, radius: 25000)
        let bounds = place.bounds
        let longitudes = try? #require(bounds.longitudes)
        #expect(longitudes?.count == 1)
        // 25 km is 0.225° of latitude, and 0.342° of longitude at 48.86° north.
        #expect(abs(bounds.latitudes.upperBound - paris.latitude - 0.2248) < 0.001)
        #expect(abs((longitudes?.first?.upperBound ?? 0) - paris.longitude - 0.3417) < 0.001)
        // The disc's northernmost and easternmost points are within the box, to rounding.
        let north = GeoCoordinate(latitude: bounds.latitudes.upperBound, longitude: paris.longitude)
        #expect(abs(PlaceFilter.distance(from: paris, to: north) - 25000) < 1)
    }

    @Test func theBoxSpansTheAntimeridianAndThePoles() {
        let fiji = PlaceFilter(center: GeoCoordinate(latitude: -17, longitude: 179.5), radius: 200_000)
        let longitudes = fiji.bounds.longitudes
        #expect(longitudes?.count == 2)
        #expect(longitudes?.first?.upperBound == 180 && longitudes?.last?.lowerBound == -180)
        #expect(fiji.contains(GeoCoordinate(latitude: -17, longitude: -179.5)))
        let condition = fiji.boxCondition(latitude: "lat", longitude: "lon")
        #expect(condition.sql == "(lat BETWEEN ? AND ? AND (lon BETWEEN ? AND ? OR lon BETWEEN ? AND ?))" && condition.arguments.count == 6)

        // Every meridian crosses a disc that holds a pole.
        let svalbard = PlaceFilter(center: GeoCoordinate(latitude: 89, longitude: 15), radius: 200_000)
        #expect(svalbard.bounds.longitudes == nil && svalbard.bounds.latitudes.upperBound == 90)
        #expect(svalbard.contains(GeoCoordinate(latitude: 89.5, longitude: -165)))
        #expect(svalbard.boxCondition(latitude: "lat", longitude: "lon").sql == "(lat BETWEEN ? AND ? AND lon IS NOT NULL)")
    }

    @Test func theCatalogFiltersOnRatingDatesAndPlace() async throws {
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Q")
        try await store.save(folder)
        func item(_ name: String, rating: Int, day: TimeInterval, location: GeoCoordinate?) -> CatalogItem {
            var item = CatalogItem(folderID: folder.id, relativePath: name, fileType: "public.jpeg", fileSize: 1, contentModified: Date(timeIntervalSince1970: 0))
            item.rating = rating
            item.captureDate = Date(timeIntervalSince1970: day * 86400)
            item.location = location
            return item
        }
        var moved = item("moved.jpg", rating: 5, day: 3, location: lyon)
        moved.locationCorrection = .place(versailles)
        moved.captureDateOverride = Date(timeIntervalSince1970: 10 * 86400)
        var removed = item("removed.jpg", rating: 0, day: 4, location: paris)
        removed.locationCorrection = .removed
        // In the box around the disc, 25 km wide at its corners, but 30 km from its center.
        let corner = GeoCoordinate(latitude: paris.latitude + 0.2, longitude: paris.longitude + 0.3)
        try await store.save([item("paris.jpg", rating: 3, day: 1, location: paris), item("lyon.jpg", rating: 4, day: 2, location: lyon),
                              moved, removed, item("corner.jpg", rating: 1, day: 5, location: corner), item("nowhere.jpg", rating: 2, day: 6, location: nil)])
        func names(_ change: (inout LibraryFilters) -> Void) async throws -> [String] {
            var query = LibraryQuery()
            query.sort = .fileName
            query.ascending = true
            change(&query.filters)
            return try await store.items(inFolder: folder.id, query: query).map(\.fileName)
        }

        #expect(try await names { $0.rating = RatingFilter(.atLeast, 4) } == ["lyon.jpg", "moved.jpg"])
        #expect(try await names { $0.rating = RatingFilter(.atMost, 1) } == ["corner.jpg", "removed.jpg"])
        #expect(try await names { $0.rating = RatingFilter(.exactly, 3) } == ["paris.jpg"])

        // The corrected date counts, not the header's; the upper bound is left out.
        let days = Date(timeIntervalSince1970: 2 * 86400) ..< Date(timeIntervalSince1970: 5 * 86400)
        #expect(try await names { $0.captureDates = days } == ["lyon.jpg", "removed.jpg"])

        // The corrected place counts; a location the user removed is no place.
        #expect(try await names { $0.place = PlaceFilter(center: paris, radius: 25000) } == ["moved.jpg", "paris.jpg"])
        #expect(try await names { $0.place = PlaceFilter(center: paris, radius: 35000) } == ["corner.jpg", "moved.jpg", "paris.jpg"])
        #expect(try await names { $0.place = PlaceFilter(center: lyon, radius: 1000); $0.rating = RatingFilter(.atLeast, 5) } == [])
    }
}
