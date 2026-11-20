import CoreLocation
import ImageIOKit
import MapKit
import SwiftUI

/// The place a library is filtered by, on an Apple map: a pin at its center and the disc of its
/// radius. A click puts the center there. The map frames the disc whenever its center or its
/// radius is set; it can be dragged and zoomed meanwhile.
///
/// Map tiles come from Apple's servers: the app needs the outgoing network entitlement for them.
struct PlaceFilterMap: View {
    /// Nil until a place is chosen: the map then shows what it chooses by itself, to click on.
    let center: GeoCoordinate?
    /// The radius drawn, in meters; follows the slider as it moves.
    let radius: Double
    /// The radius the map frames: the one the slider was let go at, so the map doesn't zoom under
    /// a slider being dragged.
    let framedRadius: Double
    let onPlace: (GeoCoordinate) -> Void

    @State private var position: MapCameraPosition

    /// How much wider than the disc the map shows: some of what is around it.
    private static let margin = 2.6

    init(center: GeoCoordinate?, radius: Double, framedRadius: Double, onPlace: @escaping (GeoCoordinate) -> Void) {
        self.center = center
        self.radius = radius
        self.framedRadius = framedRadius
        self.onPlace = onPlace
        _position = State(initialValue: Self.position(center: center, radius: framedRadius))
    }

    var body: some View {
        MapReader { proxy in
            // No rotation or tilt: north stays up.
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                if let center {
                    MapCircle(center: CLLocationCoordinate2D(center), radius: radius)
                        .foregroundStyle(Color.accentColor.opacity(0.25))
                        .stroke(Color.accentColor, lineWidth: 1.5)
                    Marker("", coordinate: CLLocationCoordinate2D(center))
                }
            }
            .mapFollowsAppAppearance()
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                guard let coordinate = proxy.convert(tap.location, from: .local) else { return }
                onPlace(GeoCoordinate(coordinate))
            })
        }
        .mapControls {
            MapZoomStepper()
        }
        .frame(height: 200)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityLabel("Map of the place to filter by")
        .help("Click to filter around another place")
        .onChange(of: center) { _, center in
            withAnimation { position = Self.position(center: center, radius: framedRadius) }
        }
        .onChange(of: framedRadius) { _, radius in
            withAnimation { position = Self.position(center: center, radius: radius) }
        }
    }

    private static func position(center: GeoCoordinate?, radius: Double) -> MapCameraPosition {
        guard let center else { return .automatic }
        let side = radius * margin
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(center), latitudinalMeters: side, longitudinalMeters: side))
    }
}

#Preview {
    @Previewable @State var center: GeoCoordinate? = GeoCoordinate(latitude: 48.8584, longitude: 2.2945)
    PlaceFilterMap(center: center, radius: 25000, framedRadius: 25000) { center = $0 }
        .frame(width: 300)
        .padding()
}
