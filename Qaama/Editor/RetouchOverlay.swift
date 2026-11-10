import AppKit
import EditModel
import EditorKit
import RenderEngine
import SwiftUI

/// The retouch tool on the canvas: dragging paints what to remove, shown as a light trail until its
/// fill is ready; the brush is a circle under the pointer. Pinching zooms and Option-dragging moves
/// around, since a plain drag paints. Points are converted between the view, the displayed image,
/// wherever the zoom and pan put it, and the original, where retouches are defined.
struct RetouchOverlay: View {
    let model: EditorModel
    let renderer: CanvasRenderer

    @State private var cursor: CGPoint?
    @State private var drag: DragKind?

    private enum DragKind {
        case painting
        case panning(from: CGPoint)
    }

    /// How much one press of [ or ] changes the brush size.
    private static let sizeStep = 1.25

    var body: some View {
        GeometryReader { proxy in
            let imageRect = renderer.imageRect(inViewOfSize: proxy.size) ?? CGRect(origin: .zero, size: proxy.size)
            ZStack {
                Color.clear
                // What is painted and not filled yet: the stroke under way, and the ones being computed.
                ForEach(model.pendingRetouches + [model.retouchStroke].compactMap(\.self)) { retouch in
                    trail(of: retouch, imageRect: imageRect)
                        .allowsHitTesting(false)
                }
                if let tool = model.retouchTool, let cursor {
                    let radius = viewRadius(tool.radius, imageRect: imageRect)
                    Circle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .background(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 3))
                        .frame(width: radius * 2, height: radius * 2)
                        .position(cursor)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): cursor = location
                case .ended: cursor = nil
                }
            }
            .gesture(dragGesture(imageRect: imageRect))
            .canvasPinchZoom(renderer)
            .background(sizeShortcuts)
        }
        .clipped()
    }

    /// The path of a retouch, as wide as its brush.
    private func trail(of retouch: Retouch, imageRect: CGRect) -> some View {
        Path { path in
            let points = retouch.points.map { viewPoint($0, imageRect: imageRect) }
            guard let first = points.first else { return }
            path.move(to: first)
            // A stroke of one point still draws: a line to itself gets its round caps.
            path.addLines(points.count > 1 ? Array(points.dropFirst()) : [first])
        }
        .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: viewRadius(retouch.radius, imageRect: imageRect) * 2, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Gestures

    private func dragGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                cursor = value.location
                if drag == nil {
                    // SwiftUI can require modifiers for a gesture but not tell two drags apart by
                    // them once both are attached, so the key is read when the drag begins.
                    if NSEvent.modifierFlags.contains(.option) {
                        drag = .panning(from: renderer.panOffset)
                    } else {
                        drag = .painting
                        model.beginRetouchStroke(at: sourcePoint(value.startLocation, imageRect: imageRect))
                    }
                }
                switch drag {
                case .painting:
                    model.extendRetouchStroke(to: sourcePoint(value.location, imageRect: imageRect))
                case let .panning(from):
                    renderer.panOffset = CGPoint(x: from.x + value.translation.width, y: from.y + value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                if case .painting = drag {
                    model.endRetouchStroke()
                }
                drag = nil
            }
    }

    /// The [ and ] keys shrink and grow the brush, as they do for the mask brush.
    private var sizeShortcuts: some View {
        Group {
            Button("") { model.setRetouchRadius((model.retouchTool?.radius ?? 0.02) / Self.sizeStep) }
                .keyboardShortcut("[", modifiers: [])
            Button("") { model.setRetouchRadius((model.retouchTool?.radius ?? 0.02) * Self.sizeStep) }
                .keyboardShortcut("]", modifiers: [])
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    // MARK: - Coordinates

    private func sourcePoint(_ location: CGPoint, imageRect: CGRect) -> UnitPoint2D {
        model.sourcePoint(fromDisplayed: UnitPoint2D(x: (location.x - imageRect.minX) / imageRect.width, y: (location.y - imageRect.minY) / imageRect.height))
    }

    private func viewPoint(_ source: UnitPoint2D, imageRect: CGRect) -> CGPoint {
        let displayed = model.displayedPoint(fromSource: source)
        return CGPoint(x: imageRect.minX + displayed.x * imageRect.width, y: imageRect.minY + displayed.y * imageRect.height)
    }

    /// A brush radius (a fraction of the original's long edge) in points of this view: geometry
    /// turns and crops the original but never resizes it, so its pixels are the displayed image's.
    private func viewRadius(_ radius: Double, imageRect: CGRect) -> CGFloat {
        guard let size = model.sourceImage?.pixelSize, let displayed = renderer.image?.extent, displayed.width > 0 else { return 0 }
        return CGFloat(radius) * max(size.width, size.height) * imageRect.width / displayed.width
    }
}
