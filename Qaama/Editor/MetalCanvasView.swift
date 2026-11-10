import MetalKit
import RenderEngine
import SwiftUI

/// Hosts the renderer's Metal view in SwiftUI and adds zoom (pinch) and pan (drag) gestures.
struct MetalCanvasView: View {
    let renderer: CanvasRenderer

    /// The pan when the drag under way began; nil between drags. Read from the renderer at that
    /// moment rather than remembered, because the session resets the viewport when the photo changes.
    @State private var panAtGestureStart: CGPoint?

    var body: some View {
        MetalViewRepresentable(renderer: renderer)
            .canvasPinchZoom(renderer)
            .simultaneousGesture(drag)
            .onTapGesture(count: 2) { resetViewport() }
            .help("Pinch to zoom, drag to pan, double-click to fit")
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

/// Pinch to zoom the canvas, for the canvas itself and for the overlays that cover it.
private struct CanvasPinchZoom: ViewModifier {
    let renderer: CanvasRenderer
    /// The zoom when the pinch under way began; nil between pinches. Read from the renderer at that
    /// moment rather than remembered, because the session resets the viewport when the photo changes.
    @State private var zoomAtGestureStart: CGFloat?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = zoomAtGestureStart ?? renderer.zoom
                    zoomAtGestureStart = start
                    renderer.setZoom(start * value.magnification)
                }
                .onEnded { _ in zoomAtGestureStart = nil }
        )
    }
}

extension View {
    func canvasPinchZoom(_ renderer: CanvasRenderer) -> some View {
        modifier(CanvasPinchZoom(renderer: renderer))
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
