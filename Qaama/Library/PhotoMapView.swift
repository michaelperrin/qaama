import LibraryKit
import MapKit
import SwiftUI

/// The photos of a library on an Apple map, where they were taken: one thumbnail per group of
/// neighbors, with their number, regrouped as the map is zoomed (see `PhotoMapModel`). A click
/// selects the photos of a group, as in the grid; a double click asks to see them.
///
/// The map only shows once the positions are read, already framed on the photos: opened before, it
/// would show the system's default region (the user's country) with nothing on it, then jump.
///
/// Map tiles come from Apple's servers: the app needs the outgoing network entitlement for them.
struct PhotoMapView: View {
    let source: any LibrarySource
    let model: PhotoMapModel
    @Binding var selection: Set<LibraryAsset.ID>
    /// Shows the photos of a group, on a double click.
    let onOpen: ([LibraryAsset.ID]) -> Void

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            switch model.locatedCount {
            case nil:
                // A few hundred milliseconds for a large library, the first time only.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case 0 where source.indexingProgress != nil:
                // The index holds the positions and isn't there yet; the bar above says so.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case 0:
                ContentUnavailableView("No Photos on the Map", systemImage: "mappin.slash",
                                       description: Text(source.query.isUnfiltered ? "None of these photos has a location." : "None of the matching photos has a location."))
            default:
                PhotoMapCanvas(model: model, selection: $selection, onOpen: onOpen)
            }
        }
        // Loaded again when the listing or the positions change; a no-op when the map comes back as it was.
        .task(id: PhotoMapModel.Content(source)) {
            await model.load(from: source)
        }
        .onChange(of: displayScale, initial: true) { _, scale in
            model.coverPixelSize = PhotoClusterMarker.requestPixels(displayScale: scale)
        }
    }
}

/// The map itself, for a model that has photos to show. It opens where the user left it, or framed
/// on all the photos.
private struct PhotoMapCanvas: View {
    let model: PhotoMapModel
    @Binding var selection: Set<LibraryAsset.ID>
    let onOpen: ([LibraryAsset.ID]) -> Void

    @State private var position: MapCameraPosition
    /// The size of the map, in points: with the region shown, it tells the zoom.
    @State private var size = CGSize.zero
    /// The group last clicked, to highlight it, by its square: after a zoom the thumbnail showing the
    /// same photo is another group. The photos themselves are in `selection`.
    @State private var selectedCell: UInt64?
    @AppStorage(LibraryMapStyle.key) private var style = LibraryMapStyle.standard

    /// How much the model looks beyond the edges of the map, as a share of its size: a thumbnail
    /// centered just outside still reaches in.
    private static let regionMargin = 0.15
    /// Around the photos when the map frames them all, and the least it then shows (in degrees).
    private static let extentMargin = 0.15
    private static let minimumExtentSpan = 0.02
    /// View › Zoom In and Zoom Out halve and double what the map shows, as its own zoom buttons do,
    /// between a few houses and the whole world (degrees of longitude).
    private static let zoomFactor = 2.0
    private static let zoomSpanRange = 0.001 ... 360.0

    init(model: PhotoMapModel, selection: Binding<Set<LibraryAsset.ID>>, onOpen: @escaping ([LibraryAsset.ID]) -> Void) {
        self.model = model
        _selection = selection
        self.onOpen = onOpen
        _position = State(initialValue: Self.openingPosition(for: model))
    }

    var body: some View {
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
        // Satellite keeps the names of places and the roads: they are what tells where a group is.
        .mapStyle(style == .satellite ? .hybrid : .standard)
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
            if position.positionedByUser {
                model.userMovedMap = true
            }
            show(context.region)
        }
        // Until the user moves the map, it keeps showing all the photos, including those a folder
        // still being read brings in batch after batch; afterwards it stays where the user left it.
        .onChange(of: model.extent) { _, _ in
            if !model.userMovedMap {
                position = Self.openingPosition(for: model)
            }
        }
        .onChange(of: selection) { _, new in
            if new.isEmpty {
                selectedCell = nil
            }
        }
        .focusedSceneValue(\.mapZoomAction, MapZoomAction(zoomIn: { zoom(by: 1 / Self.zoomFactor) }, zoomOut: { zoom(by: Self.zoomFactor) }))
        .accessibilityLabel("Map of where the photos were taken")
    }

    /// Shows `factor` times as much of the world around the same center.
    private func zoom(by factor: Double) {
        guard let shown = model.lastRegion else { return }
        var region = MKCoordinateRegion(shown)
        let width = min(max(region.span.longitudeDelta * factor, Self.zoomSpanRange.lowerBound), Self.zoomSpanRange.upperBound)
        region.span.latitudeDelta = min(region.span.latitudeDelta * width / region.span.longitudeDelta, 170)
        region.span.longitudeDelta = width
        // A choice of the user's as much as a pinch: the map no longer goes back to framing every photo.
        model.userMovedMap = true
        withAnimation { position = .region(region) }
    }

    /// Where the user left the map, in this library, or else all its photos.
    private static func openingPosition(for model: PhotoMapModel) -> MapCameraPosition {
        if model.userMovedMap, let region = model.lastRegion {
            return .region(MKCoordinateRegion(region))
        }
        guard let extent = model.extent else { return .automatic }
        return .region(MKCoordinateRegion(extent, margin: extentMargin, minimumSpan: minimumExtentSpan))
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
