import MetalKit
import RenderEngine
import SwiftUI

/// Hosts the renderer's Metal view in SwiftUI and adds zoom (pinch) and pan (drag) gestures.
struct MetalCanvasView: View {
    let renderer: CanvasRenderer

    /// Zoom and pan when the gesture under way began; nil between gestures. Read from the renderer
    /// at that moment rather than remembered, because the session resets the viewport when the
    /// photo changes.
    @State private var zoomAtGestureStart: CGFloat?
    @State private var panAtGestureStart: CGPoint?

    var body: some View {
        MetalViewRepresentable(renderer: renderer)
            .gesture(magnify)
            .simultaneousGesture(drag)
            .onTapGesture(count: 2) { resetViewport() }
            .help("Pinch to zoom, drag to pan, double-click to fit")
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomAtGestureStart ?? renderer.zoom
                zoomAtGestureStart = start
                renderer.setZoom(start * value.magnification)
            }
            .onEnded { _ in zoomAtGestureStart = nil }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = panAtGestureStart ?? renderer.panOffset
                panAtGestureStart = start
                renderer.panOffset = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            }
            .onEnded { _ in panAtGestureStart = nil }
    }

    private func resetViewport() {
        renderer.zoom = 1
        renderer.panOffset = .zero
    }
}

#if canImport(AppKit)
private struct MetalViewRepresentable: NSViewRepresentable {
    let renderer: CanvasRenderer

    func makeNSView(context _: Context) -> MTKView {
        renderer.makeView()
    }

    func updateNSView(_: MTKView, context _: Context) {}
}
#else
private struct MetalViewRepresentable: UIViewRepresentable {
    let renderer: CanvasRenderer

    func makeUIView(context _: Context) -> MTKView {
        renderer.makeView()
    }

    func updateUIView(_: MTKView, context _: Context) {}
}
#endif
