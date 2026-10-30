import CoreGraphics
import CoreImage
import EditModel
import Foundation
import Synchronization

/// Paints brush strokes into a grayscale bitmap at analysis resolution and hands it to the mask
/// renderer scaled to the reference image. Results are cached by stroke content, so dragging a
/// slider on a brushed layer never repaints.
nonisolated enum BrushRenderer {
    /// Long edge of the bitmap strokes are painted into.
    static let paintSize: CGFloat = 1024
    private static let cache = Mutex<[(key: Int, image: CIImage)]>([])

    static func render(_ brush: BrushMask, extent: CGRect) -> CIImage? {
        guard !brush.strokes.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
        var hasher = Hasher()
        hasher.combine(brush)
        hasher.combine(Int(extent.width))
        hasher.combine(Int(extent.height))
        let key = hasher.finalize()
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

    private static func paint(_ brush: BrushMask, extent: CGRect) -> CIImage? {
        let scale = min(1, paintSize / max(extent.width, extent.height))
        let width = max(1, Int(extent.width * scale)), height = max(1, Int(extent.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let longEdge = CGFloat(max(width, height))
        let colorSpace = CGColorSpaceCreateDeviceGray()

        // Each stroke is a row of radial "dabs" along its path: flat at `value` up to the hardness
        // radius, fading to nothing at the edge. Painting keeps the maximum, erasing the minimum.
        for stroke in brush.strokes {
            guard let first = stroke.points.first else { continue }
            let radius = max(0.75, CGFloat(stroke.radius) * longEdge)
            let value: CGFloat = stroke.erases ? 0 : CGFloat(stroke.opacity)
            let edge: CGFloat = stroke.erases ? 1 : 0
            let hardness = CGFloat(min(max(stroke.hardness, 0), 0.98))
            guard let gradient = CGGradient(colorsSpace: colorSpace,
                                            colors: [CGColor(gray: value, alpha: 1), CGColor(gray: value, alpha: 1), CGColor(gray: edge, alpha: 1)] as CFArray,
                                            locations: [0, hardness, 1]) else { continue }
            context.setBlendMode(stroke.erases ? .darken : .lighten)
            var previous = point(first, width: width, height: height)
            var dabs = [previous]
            let spacing = max(1, radius * 0.2)
            for next in stroke.points.dropFirst() {
                let target = point(next, width: width, height: height)
                let distance = hypot(target.x - previous.x, target.y - previous.y)
                let steps = max(1, Int(distance / spacing))
                for step in 1 ... steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    dabs.append(CGPoint(x: previous.x + (target.x - previous.x) * t, y: previous.y + (target.y - previous.y) * t))
                }
                previous = target
            }
            for dab in dabs {
                context.saveGState()
                context.addEllipse(in: CGRect(x: dab.x - radius, y: dab.y - radius, width: radius * 2, height: radius * 2))
                context.clip()
                context.drawRadialGradient(gradient, startCenter: dab, startRadius: 0, endCenter: dab, endRadius: radius, options: [])
                context.restoreGState()
            }
        }
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage)
        let transform = CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
        return image.transformed(by: transform).clampedToExtent().cropped(to: extent)
    }

    /// Unit point (origin top-left) to bitmap coordinates (Core Graphics, origin bottom-left).
    private static func point(_ point: UnitPoint2D, width: Int, height: Int) -> CGPoint {
        CGPoint(x: point.x * Double(width), y: (1 - point.y) * Double(height))
    }
}
