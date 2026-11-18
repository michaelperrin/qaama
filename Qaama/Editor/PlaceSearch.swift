import CoreLocation
import EditorKit
import ImageIOKit
import MapKit

/// Places found by name through Apple's search service (MapKit), for the Location section. Needs
/// the outgoing network entitlement, as the map tiles do.
enum PlaceSearch {
    /// How many results the list shows: enough to tell places of the same name apart.
    private static let limit = 6
    /// Side of the area searched first around the photo's place: results nearby come first, others
    /// still come.
    private static let nearbySpan: CLLocationDistance = 50000

    static func apple(_ text: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let near {
            request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(near), latitudinalMeters: nearbySpan, longitudinalMeters: nearbySpan)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(limit).map { item in
            let coordinate = item.location.coordinate
            let title = item.name ?? item.address?.shortAddress ?? text
            let subtitle = [item.address?.shortAddress, item.addressRepresentations?.cityWithContext]
                .compactMap(\.self)
                .first { $0 != title } ?? ""
            return PlaceSuggestion(title: title, subtitle: subtitle,
                                   coordinate: GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }
}
