import AppKit
import MapKit
import OSLog
import SwiftUI

extension View {
    /// Draws the `Map` this is applied to in the app's appearance (Settings › Appearance) rather
    /// than the system's.
    ///
    /// A workaround: MapKit follows the system's appearance and ignores the one it inherits from
    /// its window, `NSApp.appearance` included (measured: under a dark app on a light system, the
    /// `MKMapView` inside a SwiftUI `Map` stays `aqua`, as does a bare `MKMapView`; neither the
    /// window's appearance nor `colorScheme` changes it). Only an appearance set on the map view
    /// itself does, and SwiftUI doesn't hand that view out, so it is looked up in the window. If a
    /// later system draws `Map` differently and the view isn't found, the map simply follows the
    /// system again.
    func mapFollowsAppAppearance() -> some View {
        background(MapAppearanceBridge())
    }
}

/// An empty view laid out behind a `Map`, with the same frame, that finds the map's `MKMapView`
/// and gives it its own effective appearance, again whenever that changes.
private struct MapAppearanceBridge: NSViewRepresentable {
    func makeNSView(context _: Context) -> MapAppearanceBridgeView {
        MapAppearanceBridgeView()
    }

    func updateNSView(_ view: MapAppearanceBridgeView, context _: Context) {
        view.applySoon()
    }
}

private final class MapAppearanceBridgeView: NSView {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "MapAppearance")

    private weak var mapView: MKMapView?

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySoon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func layout() {
        super.layout()
        if mapView == nil {
            applySoon()
        }
    }

    /// After the current update: SwiftUI may install the map's view after this one.
    func applySoon() {
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        guard let window else { return }
        if mapView?.window !== window {
            mapView = findMapView(in: window)
            if mapView == nil {
                Self.logger.debug("No MKMapView found behind the map")
                return
            }
        }
        // The plain light or dark appearance: the map view has no use for vibrant variants.
        let name = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        if mapView?.appearance?.name != name {
            mapView?.appearance = NSAppearance(named: name)
        }
    }

    /// The map view this one lies behind: the one whose frame in the window is closest to ours,
    /// so that another map of the window (the Info panel's) is never taken for it.
    private func findMapView(in window: NSWindow) -> MKMapView? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        let frame = convert(bounds, to: nil)
        var best: (view: MKMapView, distance: CGFloat)?
        var stack = [root]
        while let view = stack.popLast() {
            if let map = view as? MKMapView {
                let other = map.convert(map.bounds, to: nil)
                let distance = abs(other.minX - frame.minX) + abs(other.minY - frame.minY)
                    + abs(other.width - frame.width) + abs(other.height - frame.height)
                if distance < (best?.distance ?? .infinity) {
                    best = (map, distance)
                }
            } else {
                stack.append(contentsOf: view.subviews)
            }
        }
        return best?.view
    }
}
