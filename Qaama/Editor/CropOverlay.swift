import EditModel
import EditorKit
import RenderEngine
import SwiftUI

/// The crop frame over the canvas: dimmed surroundings, thirds grid, draggable edges and corners.
/// Works in the unit coordinates of the displayed (straightened, uncropped) image.
struct CropOverlay: View {
    @Bindable var model: EditorModel

    @State private var dragStart: (crop: UnitRect, handle: Handle)?

    private static let handleHitSize: CGFloat = 14
    private static let edgeHitSize: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let imageRect = displayedImageRect(in: proxy.size)
            let frame = viewRect(for: model.geometry.crop, in: imageRect)
            ZStack {
                dimming(around: frame, in: proxy.size)
                grid(in: frame)
                Rectangle().strokeBorder(.white, lineWidth: 1).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                handles(in: frame)
            }
            .contentShape(Rectangle())
            .gesture(drag(imageRect: imageRect))
        }
    }

    // MARK: - Drawing

    private func dimming(around frame: CGRect, in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(frame)
        }
        .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
    }

    private func grid(in frame: CGRect) -> some View {
        Path { path in
            for third in 1 ... 2 {
                let x = frame.minX + frame.width * CGFloat(third) / 3
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
                let y = frame.minY + frame.height * CGFloat(third) / 3
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.5), lineWidth: 0.5)
    }

    private func handles(in frame: CGRect) -> some View {
        ForEach(Handle.corners, id: \.self) { handle in
            Rectangle()
                .fill(.white)
                .frame(width: 10, height: 10)
                .position(handle.point(in: frame))
        }
    }

    // MARK: - Geometry

    /// Where the renderer draws the image at zoom 1 with no pan: fitted and centered.
    private func displayedImageRect(in size: CGSize) -> CGRect {
        guard let extent = model.renderer?.image?.extent, extent.width > 0, extent.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let fit = min(size.width / extent.width, size.height / extent.height)
        let fitted = CGSize(width: extent.width * fit, height: extent.height * fit)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    private func viewRect(for crop: UnitRect, in imageRect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + crop.x * imageRect.width, y: imageRect.minY + crop.y * imageRect.height,
               width: crop.width * imageRect.width, height: crop.height * imageRect.height)
    }

    // MARK: - Dragging

    private func drag(imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    let frame = viewRect(for: model.geometry.crop, in: imageRect)
                    dragStart = (model.geometry.crop, Handle.hit(at: value.startLocation, frame: frame))
                }
                guard let dragStart, imageRect.width > 0, imageRect.height > 0 else { return }
                let dx = value.translation.width / imageRect.width
                let dy = value.translation.height / imageRect.height
                model.geometry.crop = Self.resize(dragStart.crop, handle: dragStart.handle, dx: dx, dy: dy,
                                                  aspect: model.geometry.aspectRatio, imageAspect: imageRect.width / imageRect.height)
            }
            .onEnded { _ in
                dragStart = nil
                model.commitChange()
            }
    }

    /// Applies a drag to a crop rectangle: moves it, or pulls the dragged edges, keeping the aspect ratio
    /// when one is locked and staying inside the image.
    static func resize(_ start: UnitRect, handle: Handle, dx: Double, dy: Double, aspect: Double?, imageAspect: Double) -> UnitRect {
        var rect = start
        if handle == .inside {
            rect.x += dx
            rect.y += dy
            return rect.clamped()
        }
        var minX = start.x, maxX = start.maxX, minY = start.y, maxY = start.maxY
        if handle.movesLeft {
            minX = min(start.x + dx, maxX - UnitRect.minimumSide)
        }
        if handle.movesRight {
            maxX = max(start.maxX + dx, minX + UnitRect.minimumSide)
        }
        if handle.movesTop {
            minY = min(start.y + dy, maxY - UnitRect.minimumSide)
        }
        if handle.movesBottom {
            maxY = max(start.maxY + dy, minY + UnitRect.minimumSide)
        }
        rect = UnitRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        if let aspect {
            // Unit width per unit height for the wanted pixel aspect, given the image's own aspect.
            let unitAspect = aspect / imageAspect
            if handle.movesLeft || handle.movesRight, !(handle.movesTop || handle.movesBottom) {
                let height = rect.width / unitAspect
                rect.y = start.y + (start.height - height) / 2
                rect.height = height
            } else {
                let width = rect.height * unitAspect
                if handle.movesLeft {
                    rect.x = maxX - width
                }
                rect.width = width
            }
        }
        // Clamp without moving the anchored sides when possible.
        rect.width = min(rect.width, 1)
        rect.height = min(rect.height, 1)
        rect.x = min(max(rect.x, 0), 1 - rect.width)
        rect.y = min(max(rect.y, 0), 1 - rect.height)
        return rect
    }

    enum Handle: Hashable {
        case inside, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        static let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

        var movesLeft: Bool {
            [.left, .topLeft, .bottomLeft].contains(self)
        }

        var movesRight: Bool {
            [.right, .topRight, .bottomRight].contains(self)
        }

        var movesTop: Bool {
            [.top, .topLeft, .topRight].contains(self)
        }

        var movesBottom: Bool {
            [.bottom, .bottomLeft, .bottomRight].contains(self)
        }

        func point(in frame: CGRect) -> CGPoint {
            CGPoint(x: movesLeft ? frame.minX : (movesRight ? frame.maxX : frame.midX),
                    y: movesTop ? frame.minY : (movesBottom ? frame.maxY : frame.midY))
        }

        static func hit(at point: CGPoint, frame: CGRect) -> Handle {
            for corner in corners where hypot(point.x - corner.point(in: frame).x, point.y - corner.point(in: frame).y) <= handleHitSize {
                return corner
            }
            let nearLeft = abs(point.x - frame.minX) <= edgeHitSize, nearRight = abs(point.x - frame.maxX) <= edgeHitSize
            let nearTop = abs(point.y - frame.minY) <= edgeHitSize, nearBottom = abs(point.y - frame.maxY) <= edgeHitSize
            let insideX = point.x >= frame.minX - edgeHitSize && point.x <= frame.maxX + edgeHitSize
            let insideY = point.y >= frame.minY - edgeHitSize && point.y <= frame.maxY + edgeHitSize
            if nearLeft, insideY {
                return .left
            }
            if nearRight, insideY {
                return .right
            }
            if nearTop, insideX {
                return .top
            }
            if nearBottom, insideX {
                return .bottom
            }
            return .inside
        }
    }
}
