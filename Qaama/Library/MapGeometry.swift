import CoreLocation
import ImageIOKit
import LibraryKit
import MapKit

// MapKit's types stay in the app: the packages speak in `GeoCoordinate` and `GeoRegion`.

extension CLLocationCoordinate2D {
    init(_ coordinate: GeoCoordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension GeoRegion {
    /// What a map shows, widened by `margin` times its size on every side and cut at the poles; the
    /// whole world when that goes around it.
    init(_ region: MKCoordinateRegion, margin: Double = 0) {
        let height = region.span.latitudeDelta * (1 + 2 * margin), width = region.span.longitudeDelta * (1 + 2 * margin)
        let south = max(region.center.latitude - height / 2, -90), north = min(region.center.latitude + height / 2, 90)
        guard width < 360 else {
            self.init(south: south, west: -180, north: north, east: 180)
            return
        }
        self.init(south: south, west: Self.wrapped(region.center.longitude - width / 2), north: north,
                  east: Self.wrapped(region.center.longitude + width / 2))
    }

    /// A longitude brought back between -180° and 180°.
    private static func wrapped(_ longitude: Double) -> Double {
        longitude < -180 ? longitude + 360 : (longitude > 180 ? longitude - 360 : longitude)
    }
}

extension MKCoordinateRegion {
    /// The map region showing `region`, widened by `margin` times its size on every side and never
    /// tighter than `minimumSpan` degrees: a single place still shows its surroundings.
    init(_ region: GeoRegion, margin: Double = 0, minimumSpan: Double = 0) {
        let width = region.east >= region.west ? region.east - region.west : region.east - region.west + 360
        self.init(center: CLLocationCoordinate2D(region.center),
                  span: MKCoordinateSpan(latitudeDelta: min(max((region.north - region.south) * (1 + 2 * margin), minimumSpan), 170),
                                         longitudeDelta: min(max(width * (1 + 2 * margin), minimumSpan), 360)))
    }
}
