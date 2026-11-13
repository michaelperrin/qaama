import CoreLocation
import ImageIOKit
import LibraryKit
import MapKit
import SwiftUI

/// The Location section of the Info panel, next to the grid and in the editor: the map of where the
/// photo was taken and, under it, the name of the place once Apple's geocoding service has told it.
/// The name is a footer rather than a row, so the map doesn't move when it arrives.
struct LocationSection: View {
    let location: GeoCoordinate

    /// The name found, with the place it is for: a photo taken elsewhere doesn't keep the previous name.
    @State private var named: (location: GeoCoordinate, name: String)?

    var body: some View {
        Section {
            LocationMap(location: location)
                .listRowInsets(EdgeInsets())
        } header: {
            Text("Location")
        } footer: {
            if let named, named.location == location {
                Text(named.name)
                    .textSelection(.enabled)
                    .accessibilityLabel("Place: \(named.name)")
            }
        }
        .task(id: location) {
            guard let name = await PlaceNames.apple.name(for: location), !Task.isCancelled else { return }
            named = (location, name)
        }
    }
}

extension PlaceNames {
    /// Place names from Apple's geocoding service, which is sent the position rounded to a hundred
    /// meters or so; one cache for the app's lifetime. Needs the outgoing network entitlement, as
    /// the map tiles do.
    static let apple = PlaceNames { coordinate in
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let item = try await MKReverseGeocodingRequest(location: location)?.mapItems.first else { return nil }
        let address = item.addressRepresentations
        return PlaceNames.compose(city: address?.cityName ?? address?.cityWithContext, region: address?.regionName, fallback: item.name)
    }
}

#Preview {
    Form {
        LocationSection(location: GeoCoordinate(latitude: 49.7073, longitude: 0.2036))
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 320)
}
