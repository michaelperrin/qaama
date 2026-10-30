import EditModel
import EditorKit
import RenderEngine
import SwiftUI

/// Mask editing on the canvas: gradient handles to drag, brush strokes to paint. Coordinates are
/// converted between the view, the displayed (cropped) image and the mask reference frame.
struct MaskOverlay: View {
    @Bindable var model: EditorModel

    @State private var dragStart: DragStart?
    @State private var cursor: CGPoint?

    private enum DragStart {
        case linear(componentID: UUID, movingEnd: Bool, start: LinearGradientMask)
        case radial(componentID: UUID, handle: RadialHandle, start: RadialGradientMask)
        case painting
    }

    private enum RadialHandle { case center, width, height, rotation }

    /// Distance of the rotation handle beyond the width handle, in points.
    private static let rotationHandleOffset: CGFloat = 26

    private static let handleRadius: CGFloat = 7
    private static let hitRadius: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let imageRect = displayedImageRect(in: proxy.size)
            ZStack {
                Color.clear
                if let layer = model.selectedLayer, let mask = layer.mask {
                    ForEach(mask.components) { component in
                        componentHandles(component, imageRect: imageRect)
                    }
                }
                if let tool = model.brushTool, let cursor {
                    let radius = CGFloat(tool.radius) * max(imageRect.width, imageRect.height)
                    Circle()
                        .strokeBorder(tool.erases ? Color.red : Color.white, lineWidth: 1.5)
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
            .gesture(drag(imageRect: imageRect))
        }
    }

    // MARK: - Handles

    @ViewBuilder
    private func componentHandles(_ component: MaskComponent, imageRect: CGRect) -> some View {
        switch component.kind {
        case let .linearGradient(gradient):
            let start = viewPoint(gradient.start, in: imageRect), end = viewPoint(gradient.end, in: imageRect)
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            handle(at: start, filled: true)
            handle(at: end, filled: false)
        case let .radialGradient(gradient):
            let center = viewPoint(gradient.center, in: imageRect)
            let long = max(imageRect.width, imageRect.height)
            let rx = CGFloat(gradient.radiusX) * long, ry = CGFloat(gradient.radiusY) * long
            Ellipse()
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: rx * 2, height: ry * 2)
                .rotationEffect(.degrees(gradient.angle))
                .position(center)
            handle(at: center, filled: true)
            handle(at: radialHandlePoint(gradient, .width, imageRect: imageRect), filled: false)
            handle(at: radialHandlePoint(gradient, .height, imageRect: imageRect), filled: false)
            rotationHandle(at: radialHandlePoint(gradient, .rotation, imageRect: imageRect))
        default:
            EmptyView()
        }
    }

    private func handle(at point: CGPoint, filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.white : Color.black.opacity(0.4))
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .frame(width: Self.handleRadius * 2, height: Self.handleRadius * 2)
            .position(point)
    }

    private func rotationHandle(at point: CGPoint) -> some View {
        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: Self.handleRadius * 2 + 2, height: Self.handleRadius * 2 + 2)
            .background(Circle().fill(.white))
            .position(point)
            .help("Rotate")
    }

    private func radialHandlePoint(_ gradient: RadialGradientMask, _ handle: RadialHandle, imageRect: CGRect) -> CGPoint {
        let center = viewPoint(gradient.center, in: imageRect)
        let long = max(imageRect.width, imageRect.height)
        let angle = gradient.angle * .pi / 180
        switch handle {
        case .center: return center
        case .width:
            let r = CGFloat(gradient.radiusX) * long
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        case .height:
            let r = CGFloat(gradient.radiusY) * long
            return CGPoint(x: center.x - r * sin(angle), y: center.y + r * cos(angle))
        case .rotation:
            let r = CGFloat(gradient.radiusX) * long + Self.rotationHandleOffset
            return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
    }

    // MARK: - Gestures

    private func drag(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = hitTest(value.startLocation, imageRect: imageRect)
                    if case .painting = dragStart {
                        model.beginStroke(at: referencePoint(value.startLocation, imageRect: imageRect))
                    }
                }
                guard let dragStart else { return }
                let point = referencePoint(value.location, imageRect: imageRect)
                switch dragStart {
                case .painting:
                    model.extendStroke(to: point)
                case let .linear(componentID, movingEnd, _):
                    update(componentID) { kind in
                        guard case var .linearGradient(gradient) = kind else { return kind }
                        if movingEnd {
                            gradient.end = point
                        } else {
                            gradient.start = point
                        }
                        return .linearGradient(gradient)
                    }
                case let .radial(componentID, handle, start):
                    // Read everything from the model before mutating it: the update closure runs under
                    // exclusive access to the recipe, and reading it there is a runtime violation.
                    let center = viewPoint(start.center, in: imageRect)
                    let long = max(imageRect.width, imageRect.height)
                    update(componentID) { kind in
                        guard case var .radialGradient(gradient) = kind else { return kind }
                        let dx = value.location.x - center.x, dy = value.location.y - center.y
                        let angle = start.angle * .pi / 180
                        switch handle {
                        case .center:
                            gradient.center = point
                        case .width:
                            // Projected on the ellipse's own axis: the handle only resizes.
                            gradient.radiusX = max(0.01, Double(abs(dx * cos(angle) + dy * sin(angle)) / long))
                        case .height:
                            gradient.radiusY = max(0.01, Double(abs(-dx * sin(angle) + dy * cos(angle)) / long))
                        case .rotation:
                            gradient.angle = Double(atan2(dy, dx)) * 180 / .pi
                        }
                        return .radialGradient(gradient)
                    }
                }
            }
            .onEnded { _ in
                if case .painting = dragStart {
                    model.endStroke()
                } else if dragStart != nil {
                    model.commitChange()
                }
                dragStart = nil
            }
    }

    private func hitTest(_ location: CGPoint, imageRect: CGRect) -> DragStart? {
        guard let mask = model.selectedLayer?.mask else { return nil }
        for component in mask.components {
            switch component.kind {
            case let .linearGradient(gradient):
                if distance(location, viewPoint(gradient.start, in: imageRect)) <= Self.hitRadius {
                    return .linear(componentID: component.id, movingEnd: false, start: gradient)
                }
                if distance(location, viewPoint(gradient.end, in: imageRect)) <= Self.hitRadius {
                    return .linear(componentID: component.id, movingEnd: true, start: gradient)
                }
            case let .radialGradient(gradient):
                for handle in [RadialHandle.rotation, .width, .height, .center] where distance(location, radialHandlePoint(gradient, handle, imageRect: imageRect)) <= Self.hitRadius {
                    return .radial(componentID: component.id, handle: handle, start: gradient)
                }
            default:
                continue
            }
        }
        return model.brushTool != nil ? .painting : nil
    }

    private func update(_ componentID: UUID, _ change: (MaskKind) -> MaskKind) {
        guard let layer = model.selectedLayer else { return }
        model.updateMask(layer.id) { mask in
            if let index = mask.components.firstIndex(where: { $0.id == componentID }) {
                mask.components[index].kind = change(mask.components[index].kind)
            }
        }
    }

    // MARK: - Coordinates

    /// Where the renderer draws the image at zoom 1 with no pan: fitted and centered.
    private func displayedImageRect(in size: CGSize) -> CGRect {
        guard let extent = model.renderer?.image?.extent, extent.width > 0, extent.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let fit = min(size.width / extent.width, size.height / extent.height)
        let fitted = CGSize(width: extent.width * fit, height: extent.height * fit)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    private func viewPoint(_ reference: UnitPoint2D, in imageRect: CGRect) -> CGPoint {
        let displayed = model.displayedPoint(fromReference: reference)
        return CGPoint(x: imageRect.minX + displayed.x * imageRect.width, y: imageRect.minY + displayed.y * imageRect.height)
    }

    private func referencePoint(_ location: CGPoint, imageRect: CGRect) -> UnitPoint2D {
        let displayed = UnitPoint2D(x: (location.x - imageRect.minX) / imageRect.width, y: (location.y - imageRect.minY) / imageRect.height)
        return model.referencePoint(fromDisplayed: displayed)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
