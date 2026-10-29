import MetalKit
import RenderEngine
import SwiftUI

/// Hosts the renderer's Metal view in SwiftUI and adds zoom (pinch) and pan (drag) gestures.
struct MetalCanvasView: View {
    let renderer: CanvasRenderer

    @State private var zoomAtGestureStart: CGFloat = 1
    @State private var panAtGestureStart: CGPoint = .zero

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
                renderer.zoom = (zoomAtGestureStart * value.magnification).clampedZoom
            }
            .onEnded { _ in zoomAtGestureStart = renderer.zoom }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                renderer.panOffset = CGPoint(
                    x: panAtGestureStart.x + value.translation.width,
                    y: panAtGestureStart.y + value.translation.height
                )
            }
            .onEnded { _ in panAtGestureStart = renderer.panOffset }
    }

    private func resetViewport() {
        renderer.zoom = 1
        renderer.panOffset = .zero
        zoomAtGestureStart = 1
        panAtGestureStart = .zero
    }
}

private extension CGFloat {
    var clampedZoom: CGFloat {
        Swift.min(Swift.max(self, 0.25), 16)
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
