import CoreGraphics
import CoreImage
import EditModel
import Foundation
import Synchronization

/// Paints brush strokes into a grayscale bitmap at analysis resolution and hands it to the mask
/// renderer scaled to the reference image.
///
/// Two caches keep painting off the hot path. Finished bitmaps are kept by stroke content, so
/// dragging a slider on a brushed layer never repaints. The bitmap of the brush painted last stays
/// open as a `Painter`: while a stroke grows point by point, only the new dabs are drawn into it,
/// so a drag costs a few dabs instead of every stroke of the mask.
nonisolated enum BrushRenderer {
    /// Long edge of the bitmap strokes are painted into.
    static let paintSize: CGFloat = 1024
    /// Distance between two dabs along a stroke, as a fraction of the dab radius.
    static let dabSpacing: CGFloat = 0.2

    /// What a painted bitmap depends on. Compared by value on lookup: a hash alone could hand a
    /// different stroke set's mask back on a collision.
    private struct Key: Hashable {
        var brush: BrushMask
        var width: Int
        var height: Int
    }

    /// An open bitmap and the brush it holds so far. Not thread-safe by itself: every access goes
    /// through the `painter` mutex, which is why it can be declared Sendable.
    private final class Painter: @unchecked Sendable {
        let context: CGContext
        let width: Int
        let height: Int
        var brush: BrushMask

        init(context: CGContext, width: Int, height: Int, brush: BrushMask) {
            self.context = context
            self.width = width
            self.height = height
            self.brush = brush
        }
    }

    private static let cache = Mutex<[(key: Key, image: CIImage)]>([])
    private static let painter = Mutex<Painter?>(nil)

    /// Forgets every painted bitmap; lets tests compare an incremental paint with a fresh one.
    static func resetCaches() {
        cache.withLock { $0.removeAll() }
        painter.withLock { $0 = nil }
    }

    static func render(_ brush: BrushMask, extent: CGRect) -> CIImage? {
        guard !brush.strokes.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
        let key = Key(brush: brush, width: Int(extent.width), height: Int(extent.height))
        if let cached = cache.withLock({ $0.first { $0.key == key }?.image }) {
            return cached
        }
        guard let painted = paint(brush, extent: extent) else { return nil }
        cache.withLock { entries in
            entries.insert((key, painted), at: 0)
            if entries.count > 8 {
                entries.removeLast()
            }
        }
        return painted
    }

    /// Paints `brush`, continuing the open bitmap when `brush` only adds to what it holds.
    private static func paint(_ brush: BrushMask, extent: CGRect) -> CIImage? {
        let scale = min(1, paintSize / max(extent.width, extent.height))
        let width = max(1, Int(extent.width * scale)), height = max(1, Int(extent.height * scale))
        let cgImage: CGImage? = painter.withLock { painter in
            if let open = painter, open.width == width, open.height == height, let delta = brush.additions(since: open.brush) {
                paint(delta, into: open.context, width: width, height: height)
                open.brush = brush
            } else {
                guard let context = makeContext(width: width, height: height) else { return nil }
                paint(brush.strokes.map { ($0, 0) }, into: context, width: width, height: height)
                painter = Painter(context: context, width: width, height: height, brush: brush)
            }
            // Copy on write: drawing into the context later leaves this image untouched.
            return painter?.context.makeImage()
        }
        guard let cgImage else { return nil }
        let image = CIImage(cgImage: cgImage)
        let transform = CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
        return image.transformed(by: transform).clampedToExtent().cropped(to: extent)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Dabs overlap five times over and the bitmap is upscaled bilinearly later: snapping each dab
        // to the pixel grid shows nothing and paints a full mask a third faster.
        context.interpolationQuality = .none
        return context
    }

    /// Draws each stroke from the given point index on; index 0 draws the whole stroke. A stroke is a
    /// row of radial "dabs" along its path, flat at its value up to the hardness radius and fading
    /// to the neutral value at the edge. Painting keeps the maximum, erasing the minimum, so the
    /// square dab image needs no clipping: its corners are neutral.
    private static func paint(_ strokes: [(stroke: BrushMask.Stroke, from: Int)], into context: CGContext, width: Int, height: Int) {
        let longEdge = CGFloat(max(width, height))
        for (stroke, from) in strokes where from < stroke.points.count {
            let radius = max(0.75, CGFloat(stroke.radius) * longEdge)
            guard let dab = dabImage(for: stroke, radius: radius) else { continue }
            context.setBlendMode(stroke.erases ? .darken : .lighten)
            let spacing = max(1, radius * dabSpacing)
            var dabs: [CGPoint] = []
            var previous: CGPoint
            if from == 0 {
                previous = point(stroke.points[0], width: width, height: height)
                dabs.append(previous)
            } else {
                previous = point(stroke.points[from - 1], width: width, height: height)
            }
            for next in stroke.points[max(from, 1)...] {
                let target = point(next, width: width, height: height)
                let distance = hypot(target.x - previous.x, target.y - previous.y)
                let steps = max(1, Int(distance / spacing))
                for step in 1 ... steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    dabs.append(CGPoint(x: previous.x + (target.x - previous.x) * t, y: previous.y + (target.y - previous.y) * t))
                }
                previous = target
            }
            for center in dabs {
                context.draw(dab, in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }

    /// One dab of a stroke: a radial gradient rendered once, then stamped along the path. Drawing
    /// a small image is several times cheaper than evaluating a gradient per dab.
    private static func dabImage(for stroke: BrushMask.Stroke, radius: CGFloat) -> CGImage? {
        let size = max(2, Int((radius * 2).rounded(.up)))
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let value: CGFloat = stroke.erases ? 0 : CGFloat(stroke.opacity)
        let neutral: CGFloat = stroke.erases ? 1 : 0
        let hardness = CGFloat(min(max(stroke.hardness, 0), 0.98))
        context.setFillColor(gray: neutral, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let gradient = CGGradient(colorsSpace: colorSpace,
                                        colors: [CGColor(gray: value, alpha: 1), CGColor(gray: value, alpha: 1), CGColor(gray: neutral, alpha: 1)] as CFArray,
                                        locations: [0, hardness, 1]) else { return nil }
        let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size) / 2, options: [])
        return context.makeImage()
    }

    /// Unit point (origin top-left) to bitmap coordinates (Core Graphics, origin bottom-left).
    private static func point(_ point: UnitPoint2D, width: Int, height: Int) -> CGPoint {
        CGPoint(x: point.x * Double(width), y: (1 - point.y) * Double(height))
    }
}

extension BrushMask {
    /// What painting `self` adds on top of `previous`: whole new strokes, and the points appended to
    /// the stroke `previous` ended with. Nil when `self` is not a continuation of `previous`, that
    /// is when any earlier stroke differs or the last shared stroke changed otherwise than by
    /// gaining points. Dabs blend with max or min within a stroke, so appending them later paints
    /// the same picture as painting the stroke in one go.
    nonisolated func additions(since previous: BrushMask) -> [(stroke: Stroke, from: Int)]? {
        let shared = previous.strokes.count
        guard shared <= strokes.count, shared > 0 else { return shared == 0 ? strokes.map { ($0, 0) } : nil }
        guard strokes[..<(shared - 1)].elementsEqual(previous.strokes[..<(shared - 1)]) else { return nil }
        let last = previous.strokes[shared - 1], grown = strokes[shared - 1]
        guard grown.radius == last.radius, grown.hardness == last.hardness, grown.opacity == last.opacity, grown.erases == last.erases,
              grown.points.count >= last.points.count, grown.points[..<last.points.count].elementsEqual(last.points) else { return nil }
        var additions: [(stroke: Stroke, from: Int)] = []
        if grown.points.count > last.points.count {
            additions.append((grown, last.points.count))
        }
        additions += strokes[shared...].map { ($0, 0) }
        return additions
    }
}
