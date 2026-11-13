import LibraryKit
import MapKit
import SwiftUI

/// The photos of a library on an Apple map, where they were taken: one thumbnail per group of
/// neighbors, with their number, regrouped as the map is zoomed (see `PhotoMapModel`). A click
/// selects the photos of a group, as in the grid; a double click asks to see them.
///
/// Map tiles come from Apple's servers: the app needs the outgoing network entitlement for them.
struct PhotoMapView: View {
    let source: any LibrarySource
    let model: PhotoMapModel
    @Binding var selection: Set<LibraryAsset.ID>
    /// Shows the photos of a group, on a double click.
    let onOpen: ([LibraryAsset.ID]) -> Void

    @State private var position: MapCameraPosition
    /// The size of the map, in points: with the region shown, it tells the zoom.
    @State private var size = CGSize.zero
    /// The group last clicked, to highlight it, by its square: after a zoom the thumbnail showing the
    /// same photo is another group. The photos themselves are in `selection`.
    @State private var selectedCell: UInt64?
    @Environment(\.displayScale) private var displayScale

    /// How much the model looks beyond the edges of the map, as a share of its size: a thumbnail
    /// centered just outside still reaches in.
    private static let regionMargin = 0.15
    /// Around the photos when the map first frames them all, and the least it then shows (in degrees).
    private static let extentMargin = 0.15
    private static let minimumExtentSpan = 0.02

    init(source: any LibrarySource, model: PhotoMapModel, selection: Binding<Set<LibraryAsset.ID>>, onOpen: @escaping ([LibraryAsset.ID]) -> Void) {
        self.source = source
        self.model = model
        _selection = selection
        self.onOpen = onOpen
        // Back from the grid: the map is where it was left.
        let lastRegion = model.hasFramedPhotos ? model.lastRegion : nil
        _position = State(initialValue: lastRegion.map { .region(MKCoordinateRegion($0)) } ?? .automatic)
    }

    var body: some View {
        Group {
            if model.locatedCount == 0, source.indexingProgress == nil {
                ContentUnavailableView("No Photos on the Map", systemImage: "mappin.slash",
                                       description: Text(source.query.isUnfiltered ? "None of these photos has a location." : "None of the matching photos has a location."))
            } else {
                map
            }
        }
        // Loaded again when the listing or the positions change; a no-op when the map comes back as it was.
        .task(id: PhotoMapModel.Content(source)) {
            await model.load(from: source)
            frameAllPhotosOnce()
        }
        .onChange(of: displayScale, initial: true) { _, scale in
            model.coverPixelSize = PhotoClusterMarker.requestPixels(displayScale: scale)
        }
        .onChange(of: selection) { _, new in
            if new.isEmpty {
                selectedCell = nil
            }
        }
    }

    private var map: some View {
        // No rotation or tilt: north stays up, as in the Info panel's map.
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(model.clusters) { cluster in
                Annotation("", coordinate: CLLocationCoordinate2D(cluster.coordinate)) {
                    PhotoClusterMarker(cluster: cluster, image: model.cover(of: cluster), isSelected: selectedCell == cluster.cell)
                        .equatable()
                        // The grid's gestures: both fire on a double click, the selection first.
                        .gesture(TapGesture(count: 2).onEnded { onOpen(model.assetIDs(in: cluster)) })
                        .simultaneousGesture(TapGesture().onEnded { select(cluster) })
                }
            }
        }
        .mapControls {
            MapZoomStepper()
            MapScaleView()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
            size = new
            // The first camera report may come before the size is known.
            if let region = model.lastRegion {
                show(MKCoordinateRegion(region))
            }
        }
        .onMapCameraChange(frequency: .continuous) { context in
            show(context.region)
        }
        .accessibilityLabel("Map of where the photos were taken")
    }

    /// Tells the model what the map shows. The zoom is the width of the whole world in points:
    /// longitudes are evenly spread across a Mercator map.
    private func show(_ region: MKCoordinateRegion) {
        model.lastRegion = GeoRegion(region)
        guard size.width > 0, region.span.longitudeDelta > 0 else { return }
        model.show(region: GeoRegion(region, margin: Self.regionMargin),
                   worldWidth: size.width * 360 / region.span.longitudeDelta,
                   spacing: PhotoClusterMarker.spacing)
    }

    /// The first time photos are there, the map shows them all; afterwards it stays where the user left it.
    private func frameAllPhotosOnce() {
        guard !model.hasFramedPhotos, let extent = model.extent else { return }
        model.hasFramedPhotos = true
        position = .region(MKCoordinateRegion(extent, margin: Self.extentMargin, minimumSpan: Self.minimumExtentSpan))
    }

    private func select(_ cluster: PhotoCluster) {
        selectedCell = cluster.cell
        selection = Set(model.assetIDs(in: cluster))
    }
}

#Preview {
    @Previewable @State var selection: Set<LibraryAsset.ID> = []
    PhotoMapView(source: SampleLibrarySource(count: 40), model: PhotoMapModel(), selection: $selection, onOpen: { _ in })
        .frame(width: 800, height: 500)
}
