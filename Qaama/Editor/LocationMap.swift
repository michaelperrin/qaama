import CoreLocation
import ImageIOKit
import MapKit
import SwiftUI

/// Where a photo was taken, on an Apple map with a pin. The map can be dragged and zoomed (pinch,
/// scroll, or the zoom buttons); the button in its corner brings it back onto the photo. Shared by
/// the editor's Info tab and the grid's Info panel.
///
/// Given `onPlace`, the map also sets the place: a click puts the pin down there, and the pin can
/// be dragged elsewhere. Without it, the map only shows.
///
/// Map tiles come from Apple's servers: the app needs the outgoing network entitlement for them.
struct LocationMap: View {
    /// Where the pin stands; nil shows no pin.
    let location: GeoCoordinate?
    /// Where the map centers when it opens and whenever this changes; the pin's place when nil.
    var focus: GeoCoordinate?
    /// Called with the place a click or a drag of the pin chose; nil when the map only shows.
    var onPlace: ((GeoCoordinate) -> Void)?

    /// Side of the area shown around the pin: a neighborhood, enough to recognize the place.
    private static let span: CLLocationDistance = 3000

    @State private var position: MapCameraPosition
    /// The pin being dragged, while it is; drawn over the map rather than by it.
    @State private var drag: PinDrag?
    /// Where the pin was let go, shown until `location` follows (the write is a moment later).
    @State private var dropped: GeoCoordinate?

    /// A drag of the pin, in the map's own coordinates: where the pin's point was when it was
    /// grabbed, and where it is now.
    private struct PinDrag {
        let start: CGPoint
        var point: CGPoint
    }

    init(location: GeoCoordinate?, focus: GeoCoordinate? = nil, onPlace: ((GeoCoordinate) -> Void)? = nil) {
        self.location = location
        self.focus = focus
        self.onPlace = onPlace
        _position = State(initialValue: Self.position(for: focus ?? location))
    }

    private var center: GeoCoordinate? {
        focus ?? location
    }

    var body: some View {
        MapReader { proxy in
            // No rotation or tilt: north stays up, so there is nothing to put back but the framing.
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                if let shown = dropped ?? location {
                    if onPlace != nil {
                        Annotation("", coordinate: CLLocationCoordinate2D(shown), anchor: .bottom) {
                            // Stays in place, unseen, while the pin is dragged: it holds the gesture.
                            PinImage(isLifted: false)
                                .opacity(drag == nil ? 1 : 0)
                                .gesture(pinDrag(proxy, from: shown))
                                .help("Drag to move the photo's location")
                                .accessibilityLabel("Location pin")
                        }
                    } else {
                        // No title: the pin alone says where; a caption under it only repeated "Photo".
                        Marker("", coordinate: CLLocationCoordinate2D(shown))
                    }
                }
            }
            // Only while setting the place: a click to look at the map must not move the photo.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                guard let onPlace, let coordinate = proxy.convert(tap.location, from: .local) else { return }
                onPlace(GeoCoordinate(coordinate))
            }, including: onPlace == nil ? .subviews : .all)
            // The dragged pin, drawn by SwiftUI where the pointer is: MapKit moves its annotations a
            // frame or two late, and a pin it carried lagged and shook behind the pointer.
            .overlay(alignment: .topLeading) {
                if let drag {
                    PinImage(isLifted: true)
                        .position(x: drag.point.x, y: drag.point.y - PinImage.size / 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .mapControls {
            MapZoomStepper()
        }
        .overlay(alignment: .topTrailing) {
            Button("Recenter", systemImage: "scope") {
                withAnimation { position = Self.position(for: location ?? center) }
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
        .accessibilityLabel(onPlace == nil ? "Map of where the photo was taken" : "Map to set where the photo was taken")
        .onChange(of: focus) { _, new in
            if let new {
                withAnimation { position = Self.position(for: new) }
            }
        }
        // The view outlives the photo it was built for: another photo's place takes over the framing.
        // Not while setting the place: the pin just put down is in view, and the map mustn't move under the pointer.
        .onChange(of: location) { _, new in
            dropped = nil
            if onPlace == nil {
                position = Self.position(for: new)
            }
        }
        // A write that failed leaves `location` as it was: the pin goes back there.
        .task(id: dropped) {
            guard dropped != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            dropped = nil
        }
    }

    /// Follows the pointer from where the pin was grabbed. The translation is read in the window's
    /// coordinates, which stay still: in the pin's own, which move with it, it fed back on itself.
    private func pinDrag(_ proxy: MapProxy, from coordinate: GeoCoordinate) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard let start = drag?.start ?? proxy.convert(CLLocationCoordinate2D(coordinate), to: .local) else { return }
                drag = PinDrag(start: start, point: CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height))
            }
            .onEnded { _ in
                if let point = drag?.point, let place = proxy.convert(point, from: .local) {
                    dropped = GeoCoordinate(place)
                    onPlace?(GeoCoordinate(place))
                }
                drag = nil
            }
    }

    /// The framing the map opens on and comes back to: the photo's place at the center, or what the
    /// map chooses by itself (the whole world) when there is no place.
    private static func position(for location: GeoCoordinate?) -> MapCameraPosition {
        guard let location else { return .automatic }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(location), latitudinalMeters: span, longitudinalMeters: span))
    }
}

/// The pin of a place being set: white on red, the colors of a map pin, its point at the bottom.
/// Lifted while dragged, as a pin picked up off the map.
private struct PinImage: View {
    static let size: CGFloat = 30
    let isLifted: Bool

    var body: some View {
        Image(systemName: "mappin.circle.fill")
            .resizable()
            .foregroundStyle(.white, .red)
            .frame(width: Self.size, height: Self.size)
            .shadow(color: .black.opacity(0.3), radius: isLifted ? 4 : 1, y: isLifted ? 4 : 1)
            .scaleEffect(isLifted ? 1.15 : 1, anchor: .bottom)
            .contentShape(.circle)
    }
}

extension GeoCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

#Preview("Showing") {
    Form {
        Section("Location") {
            LocationMap(location: GeoCoordinate(latitude: 48.8584, longitude: 2.2945))
                .listRowInsets(EdgeInsets())
        }
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 300)
}

#Preview("Setting") {
    @Previewable @State var location: GeoCoordinate? = GeoCoordinate(latitude: 48.8584, longitude: 2.2945)
    Form {
        Section("Location") {
            LocationMap(location: location) { location = $0 }
                .listRowInsets(EdgeInsets())
        }
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 300)
}
