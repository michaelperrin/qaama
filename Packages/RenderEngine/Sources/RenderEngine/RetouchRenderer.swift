import CoreGraphics
import CoreImage
import EditModel
import Foundation
import HealingFill
import OSLog

/// Computes what each retouch of a recipe puts in place of what was painted out, and lays those
/// fills over the original.
///
/// A fill is an image the size of the painted region, transparent outside it, placed where it
/// belongs in the original: compositing it over the original is all the pipeline does per frame.
/// Computing one reads the pixels around the region and runs `PatchFill` on them, which takes from
/// tens of milliseconds to about a second: done once when the stroke ends, off the main actor,
/// never per slider move. Retouches apply in order, so each fill is computed on the original with
/// the earlier fills already in.
public nonisolated enum RetouchRenderer {
    /// How much wider than the brush the filled region is, as a fraction of its radius and at least
    /// `minimumGrowth` pixels: whatever of the object is left outside the region gets copied back
    /// into the fill as if it were background, so the region errs on the generous side.
    static let growth = 0.15
    static let minimumGrowth = 2.0
    /// How far around the region material is taken from, in thicknesses of the region, within these
    /// bounds in pixels. Wide enough to find material, close enough to match the place.
    static let reach = 4.0
    static let marginRange = 48.0 ... 600.0
    /// Work areas larger than this are filled on a reduced copy: a stroke across a whole 50 MP
    /// photo must not take a gigabyte and ten seconds. The fill is then softer than the photo.
    static let maximumWorkPixels = 6_000_000.0

    private static let ownContext = CIContext(options: [.cacheIntermediates: false, .name: "Qaama retouch"])
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "RetouchRenderer")

    /// `image` with the fills of `retouches` laid over it, in order. Retouches without a fill yet
    /// are left out: the photo shows what was there until their fill is ready.
    ///
    /// The result is marked as a cacheable intermediate, like the decoded original: the canvas
    /// re-runs the adjustments on every slider move, not one blend per retouch.
    public static func apply(_ retouches: [Retouch], fills: [UUID: CIImage], to image: CIImage) -> CIImage {
        let retouched = retouches.reduce(image) { laying(fills[$1.id], over: $0) }
        return retouched === image ? image : retouched.insertingIntermediate(cache: true)
    }

    /// `image` itself when there is no fill, or an empty one.
    private static func laying(_ fill: CIImage?, over image: CIImage) -> CIImage {
        guard let fill, !fill.extent.isEmpty else { return image }
        return fill.composited(over: image).cropped(to: image.extent)
    }

    /// The fills of every retouch of a recipe, computed in order; the ones in `existing` are reused
    /// and must have been computed for this same list. A retouch that can't be filled gets an
    /// empty image. Blocking: call it off the main actor.
    public static func resolveAll(_ retouches: [Retouch], image: CIImage, existing: [UUID: CIImage] = [:], context: CIContext? = nil) -> [UUID: CIImage] {
        var fills = existing
        var current = image
        for retouch in retouches {
            let fill = fills[retouch.id] ?? fill(retouch, in: current, context: context) ?? CIImage.empty()
            fills[retouch.id] = fill
            current = laying(fill, over: current)
        }
        return fills
    }

    /// The fill of one retouch on `image`, which already carries the earlier ones. Nil when there is
    /// nothing to fill or nothing to fill it from. `context` renders the pixels around the region;
    /// pass the canvas's to reuse what it has decoded. Blocking: call it off the main actor.
    public static func fill(_ retouch: Retouch, in image: CIImage, context: CIContext? = nil) -> CIImage? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1, !retouch.points.isEmpty,
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedSRGB) else { return nil }
        let clock = ContinuousClock()
        let start = clock.now

        // The painted region, in pixels of the original with the origin at the top-left.
        let brush = max(1, retouch.radius * max(extent.width, extent.height))
        let radius = brush + max(minimumGrowth, brush * growth)
        let points = retouch.points.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) }
        let whole = CGRect(origin: .zero, size: extent.size)
        let painted = points.reduce(CGRect.null) { $0.union(CGRect(x: $1.x - radius, y: $1.y - radius, width: radius * 2, height: radius * 2)) }
        let bounds = painted.intersection(whole).integral
        guard !bounds.isEmpty else { return nil }

        // Its thickness sets how far around it the fill looks.
        let margin = min(marginRange.upperBound, max(marginRange.lowerBound, thickness(of: points, radius: radius, bounds: bounds) * reach))
        let work = bounds.insetBy(dx: -margin, dy: -margin).intersection(whole).integral
        let scale = min(1, (maximumWorkPixels / (work.width * work.height)).squareRoot())
        let hole = region(points, radius: radius, in: work, scale: scale)
        guard let holeBounds = tightBounds(of: hole.mask, width: hole.width, height: hole.height) else { return nil }

        // The pixels of the work area, as display-encoded floats: patches are compared the way they
        // look, and values beyond 0…1 (a RAW's highlights) survive the round trip.
        let workRect = CGRect(x: extent.minX + work.minX, y: extent.maxY - work.maxY, width: work.width, height: work.height)
        let scaleX = CGFloat(hole.width) / work.width, scaleY = CGFloat(hole.height) / work.height
        let reduced = image.cropped(to: workRect)
            .transformed(by: CGAffineTransform(translationX: -workRect.minX, y: -workRect.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        var rgba = [Float](repeating: 0, count: hole.width * hole.height * 4)
        (context ?? ownContext).render(reduced, toBitmap: &rgba, rowBytes: hole.width * 16, bounds: CGRect(x: 0, y: 0, width: hole.width, height: hole.height),
                                       format: .RGBAf, colorSpace: colorSpace)
        var bitmap = FillBitmap(width: hole.width, height: hole.height)
        for index in 0 ..< hole.width * hole.height {
            bitmap.rgb[index * 3] = rgba[index * 4]
            bitmap.rgb[index * 3 + 1] = rgba[index * 4 + 1]
            bitmap.rgb[index * 3 + 2] = rgba[index * 4 + 2]
        }
        let read = clock.now
        guard let filled = PatchFill.fill(bitmap, hole: hole.mask) else {
            logger.notice("Retouch: nothing around a \(Int(bounds.width))x\(Int(bounds.height)) region to fill it from")
            return nil
        }

        // Only the region comes back: premultiplied, transparent where nothing was painted.
        let width = Int(holeBounds.width), height = Int(holeBounds.height)
        var patch = [Float](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let source = (Int(holeBounds.minY) + y) * hole.width + Int(holeBounds.minX) + x
                guard hole.mask[source] != 0 else { continue }
                let target = (y * width + x) * 4
                patch[target] = filled.rgb[source * 3]
                patch[target + 1] = filled.rgb[source * 3 + 1]
                patch[target + 2] = filled.rgb[source * 3 + 2]
                patch[target + 3] = 1
            }
        }
        let data = patch.withUnsafeBufferPointer { Data(buffer: $0) }
        let fill = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace)
            // From the work bitmap (rows from the top) back to the original's coordinates.
            .transformed(by: CGAffineTransform(translationX: holeBounds.minX, y: CGFloat(hole.height) - holeBounds.maxY))
            .transformed(by: CGAffineTransform(scaleX: 1 / scaleX, y: 1 / scaleY))
            .transformed(by: CGAffineTransform(translationX: workRect.minX, y: workRect.minY))
        let format = Duration.UnitsFormatStyle.units(allowed: [.milliseconds])
        logger.notice("Retouch: \(width)x\(height) region filled from a \(hole.width)x\(hole.height) area\(scale < 1 ? " (reduced)" : "", privacy: .public) in \((clock.now - start).formatted(format), privacy: .public), of which \((read - start).formatted(format), privacy: .public) reading pixels")
        return fill
    }

    // MARK: - Region

    /// How deep the painted region is at its deepest, in pixels: the brush radius for a single
    /// stroke, more where a stroke doubles back on itself. Measured on a small copy.
    static func thickness(of points: [CGPoint], radius: CGFloat, bounds: CGRect) -> Double {
        let scale = min(1, 256 / max(bounds.width, bounds.height))
        // A margin of unpainted pixels all around: depth is measured from them, and the region
        // fills its own bounds edge to edge.
        let probe = region(points, radius: radius, in: bounds.insetBy(dx: -2 / scale, dy: -2 / scale), scale: scale)
        return Double(PatchFill.depth(probe.mask, width: probe.width, height: probe.height).max() ?? 1) / scale
    }

    /// The brush's path painted into a mask covering `rect` (pixels of the original, origin
    /// top-left) at `scale`: 1 where it passed, rows from the top.
    static func region(_ points: [CGPoint], radius: CGFloat, in rect: CGRect, scale: CGFloat) -> (mask: [UInt8], width: Int, height: Int) {
        let width = max(1, Int((rect.width * scale).rounded())), height = max(1, Int((rect.height * scale).rounded()))
        var mask = [UInt8](repeating: 0, count: width * height)
        mask.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Core Graphics counts rows from the bottom, the mask from the top.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: CGFloat(width) / rect.width, y: -CGFloat(height) / rect.height)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            context.setShouldAntialias(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineWidth(radius * 2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if let first = points.first {
                // A stroke of one point is a dab; a longer one starts with the same dab.
                context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
            }
            if points.count > 1 {
                context.addLines(between: points)
                context.strokePath()
            }
        }
        for index in mask.indices {
            mask[index] = mask[index] > 127 ? 1 : 0
        }
        return (mask, width, height)
    }

    /// The smallest rectangle holding every set pixel of a mask, rows from the top; nil for an empty one.
    static func tightBounds(of mask: [UInt8], width: Int, height: Int) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where mask[y * width + x] != 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
