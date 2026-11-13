import CoreLocation
import ImageIOKit
import MapKit
import SwiftUI

/// Where a photo was taken, on an Apple map with a pin. The map can be dragged and zoomed (pinch,
/// scroll, or the zoom buttons); the button in its corner brings it back onto the photo. Shared by
/// the editor's Info tab and the grid's Info panel.
///
/// Map tiles come from Apple's servers: the app needs the outgoing network entitlement for them.
struct LocationMap: View {
    let location: GeoCoordinate

    /// Side of the area shown around the pin: a neighborhood, enough to recognize the place.
    private static let span: CLLocationDistance = 3000

    @State private var position: MapCameraPosition

    init(location: GeoCoordinate) {
        self.location = location
        _position = State(initialValue: Self.position(for: location))
    }

    var body: some View {
        // No rotation or tilt: north stays up, so there is nothing to put back but the framing.
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            // No title: the pin alone says where; a caption under it only repeated "Photo".
            Marker("", coordinate: CLLocationCoordinate2D(location))
        }
        .mapControls {
            MapZoomStepper()
        }
        .overlay(alignment: .topTrailing) {
            Button("Recenter", systemImage: "scope") {
                withAnimation { position = Self.position(for: location) }
            }
            .labelStyle(.iconOnly)
            .controlSize(.small)
            .help("Center the map on the photo")
            // Nothing to undo until the user has moved or zoomed the map.
            .disabled(!position.positionedByUser)
            .padding(6)
        }
        .frame(height: 200)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityLabel("Map of where the photo was taken")
        // The view outlives the photo it was built for: another photo's place takes over the framing.
        .onChange(of: location) { _, new in position = Self.position(for: new) }
    }

    /// The framing the map opens on and comes back to: the photo's place at the center.
    private static func position(for location: GeoCoordinate) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: CLLocationCoordinate2D(location), latitudinalMeters: span, longitudinalMeters: span))
    }
}

#Preview {
    Form {
        Section("Location") {
            LocationMap(location: GeoCoordinate(latitude: 48.8584, longitude: 2.2945))
                .listRowInsets(EdgeInsets())
        }
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 300)
}
