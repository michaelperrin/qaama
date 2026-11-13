import Foundation
import ImageIOKit
import OSLog

/// The names of the places photos were taken at ("Étretat, France"), asked once per place.
///
/// The lookup itself is handed in (the app's goes to Apple's geocoding service through MapKit), so
/// this stays free of MapKit and testable. Such services limit how often they are asked: this is for
/// the photo being looked at, not for naming every photo of a library.
public final class PlaceNames {
    /// Answers with the name of the place at a coordinate, nil when it has none, or throws when it
    /// couldn't tell (no network, too many requests): the question is then asked again next time.
    public typealias Lookup = @MainActor (GeoCoordinate) async throws -> String?

    private let lookup: Lookup
    /// Answers so far; a place without a name is remembered as such.
    private var names: [Spot: String?] = [:]
    /// Lookups under way, so the same place selected twice in a row is asked once.
    private var pending: [Spot: Task<String?, Error>] = [:]
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PlaceNames")

    public init(lookup: @escaping Lookup) {
        self.lookup = lookup
    }

    /// The name of the place at `coordinate`, or nil when it has none or can't be told right now.
    public func name(for coordinate: GeoCoordinate) async -> String? {
        let spot = Spot(coordinate)
        if let known = names[spot] {
            return known
        }
        let task = pending[spot] ?? Task { [lookup] in try await lookup(spot.coordinate) }
        pending[spot] = task
        do {
            let name = try await task.value
            names[spot] = .some(name)
            pending[spot] = nil
            return name
        } catch {
            pending[spot] = nil
            logger.notice("No place name: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// "City, Country" from the parts a geocoder gives, leaving out those it has nothing for; `fallback`
    /// (an ocean, a mountain range) when there is no city.
    public nonisolated static func compose(city: String?, region: String?, fallback: String?) -> String? {
        func filled(_ text: String?) -> String? {
            text.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let city = filled(city) else { return filled(fallback) ?? filled(region) }
        guard let region = filled(region), region != city else { return city }
        return "\(city), \(region)"
    }

    /// A coordinate rounded to a thousandth of a degree (a hundred meters or so): photos taken at
    /// the same spot share one question.
    private nonisolated struct Spot: Hashable {
        let latitude: Int
        let longitude: Int

        init(_ coordinate: GeoCoordinate) {
            latitude = Int((coordinate.latitude * 1000).rounded())
            longitude = Int((coordinate.longitude * 1000).rounded())
        }

        var coordinate: GeoCoordinate {
            GeoCoordinate(latitude: Double(latitude) / 1000, longitude: Double(longitude) / 1000)
        }
    }
}
