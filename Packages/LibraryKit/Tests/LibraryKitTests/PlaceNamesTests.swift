import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

@MainActor
struct PlaceNamesTests {
    private struct Offline: Error {}

    /// Counts the questions asked and answers as told.
    @MainActor private final class Geocoder {
        private(set) var asked: [GeoCoordinate] = []
        var answer: Result<String?, Error> = .success("Étretat, France")

        func lookup(_ coordinate: GeoCoordinate) async throws -> String? {
            asked.append(coordinate)
            try? await Task.sleep(for: .milliseconds(10))
            return try answer.get()
        }
    }

    private static let cliff = GeoCoordinate(latitude: 49.70731, longitude: 0.20362)

    @Test func asksOncePerPlace() async {
        let geocoder = Geocoder()
        let names = PlaceNames { try await geocoder.lookup($0) }

        #expect(await names.name(for: Self.cliff) == "Étretat, France")
        // A few meters away: the same spot, hence the same answer without asking.
        #expect(await names.name(for: GeoCoordinate(latitude: 49.70738, longitude: 0.20371)) == "Étretat, France")
        #expect(geocoder.asked.count == 1)
        // Another place is another question.
        _ = await names.name(for: GeoCoordinate(latitude: 48.8584, longitude: 2.2945))
        #expect(geocoder.asked.count == 2)
    }

    @Test func theSamePlaceAskedTwiceAtOnceIsLookedUpOnce() async {
        let geocoder = Geocoder()
        let names = PlaceNames { try await geocoder.lookup($0) }

        async let first = names.name(for: Self.cliff)
        async let second = names.name(for: Self.cliff)
        #expect(await first == "Étretat, France")
        #expect(await second == "Étretat, France")
        #expect(geocoder.asked.count == 1)
    }

    @Test func aPlaceWithoutANameIsRememberedAndAFailureIsAskedAgain() async {
        let geocoder = Geocoder()
        let names = PlaceNames { try await geocoder.lookup($0) }

        geocoder.answer = .failure(Offline())
        #expect(await names.name(for: Self.cliff) == nil)
        geocoder.answer = .success(nil)
        #expect(await names.name(for: Self.cliff) == nil)
        #expect(geocoder.asked.count == 2)
        // Nothing there: no need to ask again.
        geocoder.answer = .success("Étretat, France")
        #expect(await names.name(for: Self.cliff) == nil)
        #expect(geocoder.asked.count == 2)
    }

    @Test func composesTheNameFromWhatTheGeocoderHas() {
        #expect(PlaceNames.compose(city: "Étretat", region: "France", fallback: "8 Rue des Docteurs Fidelin") == "Étretat, France")
        #expect(PlaceNames.compose(city: "Monaco", region: "Monaco", fallback: nil) == "Monaco")
        #expect(PlaceNames.compose(city: "Courmayeur", region: " ", fallback: nil) == "Courmayeur")
        #expect(PlaceNames.compose(city: "", region: nil, fallback: "North Atlantic Ocean") == "North Atlantic Ocean")
        #expect(PlaceNames.compose(city: nil, region: "Iceland", fallback: "") == "Iceland")
        #expect(PlaceNames.compose(city: nil, region: nil, fallback: nil) == nil)
    }
}
