// Healing brush feasibility test: removes a painted region without any machine learning model.
// Two methods side by side, see README.md. Throwaway code, not part of the app.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Pixels

/// RGB floats in display (sRGB-encoded) values, row-major, top row first.
struct Bitmap {
    let width: Int
    let height: Int
    var rgb: [Float]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        rgb = [Float](repeating: 0, count: width * height * 3)
    }

    func cropped(to rect: Rect) -> Bitmap {
        var out = Bitmap(width: rect.width, height: rect.height)
        for y in 0 ..< rect.height {
            let from = ((rect.y + y) * width + rect.x) * 3
            out.rgb.replaceSubrange(y * rect.width * 3 ..< (y + 1) * rect.width * 3, with: rgb[from ..< from + rect.width * 3])
        }
        return out
    }

    /// Copies the pixels of `other` flagged in `mask` (same size as `other`) at `origin`.
    mutating func paste(_ other: Bitmap, at origin: Rect, where mask: [UInt8]) {
        for y in 0 ..< other.height {
            for x in 0 ..< other.width where mask[y * other.width + x] != 0 {
                let to = ((origin.y + y) * width + origin.x + x) * 3, from = (y * other.width + x) * 3
                rgb[to] = other.rgb[from]
                rgb[to + 1] = other.rgb[from + 1]
                rgb[to + 2] = other.rgb[from + 2]
            }
        }
    }
}

struct Rect {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

enum ImageFile {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func load(_ url: URL) -> Bitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var bitmap = Bitmap(width: width, height: height)
        for index in 0 ..< width * height {
            bitmap.rgb[index * 3] = Float(bytes[index * 4]) / 255
            bitmap.rgb[index * 3 + 1] = Float(bytes[index * 4 + 1]) / 255
            bitmap.rgb[index * 3 + 2] = Float(bytes[index * 4 + 2]) / 255
        }
        return bitmap
    }

    /// A mask image scaled to `width` × `height`: 1 where it is lighter than mid-gray.
    static func loadMask(_ url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes.map { $0 > 127 ? 1 : 0 } : nil
    }

    static func cgImage(_ bitmap: Bitmap) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: bitmap.width * bitmap.height * 4)
        for index in 0 ..< bitmap.width * bitmap.height {
            for channel in 0 ..< 3 {
                bytes[index * 4 + channel] = UInt8(max(0, min(255, (bitmap.rgb[index * 3 + channel] * 255).rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static func save(_ bitmap: Bitmap, to url: URL) {
        if let image = cgImage(bitmap) {
            save(image, to: url)
        }
    }

    static func save(mask: [UInt8], width: Int, height: Int, to url: URL) {
        var bitmap = Bitmap(width: width, height: height)
        for index in 0 ..< width * height where mask[index] != 0 {
            bitmap.rgb[index * 3] = 1
            bitmap.rgb[index * 3 + 1] = 1
            bitmap.rgb[index * 3 + 2] = 1
        }
        save(bitmap, to: url)
    }
}

// MARK: - Mask helpers

enum MaskOps {
    /// Box dilation by `radius` pixels, in two passes.
    static func dilated(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return mask }
        var rows = [UInt8](repeating: 0, count: mask.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var hit: UInt8 = 0
                for xx in max(0, x - radius) ... min(width - 1, x + radius) where mask[y * width + xx] != 0 {
                    hit = 1
                    break
                }
                rows[y * width + x] = hit
            }
        }
        var out = [UInt8](repeating: 0, count: mask.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var hit: UInt8 = 0
                for yy in max(0, y - radius) ... min(height - 1, y + radius) where rows[yy * width + x] != 0 {
                    hit = 1
                    break
                }
                out[y * width + x] = hit
            }
        }
        return out
    }

    /// For each masked pixel, its approximate distance to the nearest unmasked one (chamfer 3-4).
    static func depth(_ mask: [UInt8], width: Int, height: Int) -> [Float] {
        let far: Float = 1e9
        var d = mask.map { $0 != 0 ? far : 0 }
        func relax(_ index: Int, _ x: Int, _ y: Int, _ dx: Int, _ dy: Int, _ cost: Float) {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < width, ny < height else { return }
            d[index] = min(d[index], d[ny * width + nx] + cost)
        }
        for y in 0 ..< height {
            for x in 0 ..< width where d[y * width + x] > 0 {
                let i = y * width + x
                relax(i, x, y, -1, 0, 1); relax(i, x, y, 0, -1, 1); relax(i, x, y, -1, -1, 4.0 / 3); relax(i, x, y, 1, -1, 4.0 / 3)
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) where d[y * width + x] > 0 {
                let i = y * width + x
                relax(i, x, y, 1, 0, 1); relax(i, x, y, 0, 1, 1); relax(i, x, y, 1, 1, 4.0 / 3); relax(i, x, y, -1, 1, 4.0 / 3)
            }
        }
        return d
    }

    static func bounds(_ mask: [UInt8], width: Int, height: Int) -> Rect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where mask[y * width + x] != 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : Rect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func cropped(_ mask: [UInt8], width: Int, to rect: Rect) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rect.width * rect.height)
        for y in 0 ..< rect.height {
            for x in 0 ..< rect.width {
                out[y * rect.width + x] = mask[(rect.y + y) * width + rect.x + x]
            }
        }
        return out
    }

    /// Fills the unknown entries of a 3-channel field from the known ones around, ring by ring.
    static func onionFill(_ values: inout [Float], unknown: [UInt8], width: Int, height: Int) {
        var pending = unknown
        var frontier = (0 ..< width * height).filter { pending[$0] != 0 }
        while !frontier.isEmpty {
            var filled: [(Int, Float, Float, Float)] = []
            var rest: [Int] = []
            for index in frontier {
                let x = index % width, y = index / width
                var sum: (Float, Float, Float) = (0, 0, 0)
                var count: Float = 0
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height, pending[ny * width + nx] == 0 else { continue }
                        let n = (ny * width + nx) * 3
                        sum.0 += values[n]; sum.1 += values[n + 1]; sum.2 += values[n + 2]
                        count += 1
                    }
                }
                if count > 0 {
                    filled.append((index, sum.0 / count, sum.1 / count, sum.2 / count))
                } else {
                    rest.append(index)
                }
            }
            guard !filled.isEmpty else { return }
            for (index, r, g, b) in filled {
                values[index * 3] = r; values[index * 3 + 1] = g; values[index * 3 + 2] = b
                pending[index] = 0
            }
            frontier = rest
        }
    }
}

/// Half-size copies of an image and its hole. A coarse pixel is a hole as soon as one of its four
/// pixels is, so known coarse pixels never mix in what is being removed.
enum Pyramid {
    static func half(_ image: Bitmap, hole: [UInt8]) -> (Bitmap, [UInt8]) {
        let w = (image.width + 1) / 2, h = (image.height + 1) / 2
        var out = Bitmap(width: w, height: h)
        var outHole = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var sum: (Float, Float, Float) = (0, 0, 0)
                var isHole: UInt8 = 0
                for dy in 0 ... 1 {
                    for dx in 0 ... 1 {
                        let sx = min(image.width - 1, x * 2 + dx), sy = min(image.height - 1, y * 2 + dy)
                        let s = sy * image.width + sx
                        sum.0 += image.rgb[s * 3]; sum.1 += image.rgb[s * 3 + 1]; sum.2 += image.rgb[s * 3 + 2]
                        isHole |= hole[s]
                    }
                }
                let o = (y * w + x) * 3
                out.rgb[o] = sum.0 / 4; out.rgb[o + 1] = sum.1 / 4; out.rgb[o + 2] = sum.2 / 4
                outHole[y * w + x] = isHole
            }
        }
        return (out, outHole)
    }

    /// Levels from full size down to a long edge of at most `coarsest` pixels.
    static func levels(_ image: Bitmap, hole: [UInt8], coarsest: Int, minimumShortEdge: Int) -> [(image: Bitmap, hole: [UInt8])] {
        var levels = [(image: image, hole: hole)]
        while let last = levels.last, max(last.image.width, last.image.height) > coarsest,
              (min(last.image.width, last.image.height) + 1) / 2 >= minimumShortEdge
        {
            levels.append(half(last.image, hole: last.hole))
        }
        return levels
    }
}

// MARK: - Method 1: one source area, blended in

/// Classic healing: finds the translation whose surroundings look most like the hole's, copies that
/// area in, and adds a smooth correction (a membrane, as in Poisson cloning) so color and light meet
/// the hole's edge exactly.
enum SourceHeal {
    static func fill(_ image: Bitmap, hole: [UInt8], thickness: Int) -> (result: Bitmap, offset: (x: Int, y: Int))? {
        let ringWidth = max(3, min(12, thickness / 2))
        let levels = Pyramid.levels(image, hole: hole, coarsest: 96, minimumShortEdge: 8)

        // Coarsest level: every translation. Then each finer level looks one pixel around.
        var best: (x: Int, y: Int)?
        for (index, level) in levels.enumerated().reversed() {
            let w = level.image.width, h = level.image.height
            let region = MaskOps.dilated(level.hole, width: w, height: h, radius: max(2, ringWidth >> index))
            let regionPixels = (0 ..< w * h).filter { region[$0] != 0 }
            let ringPixels = regionPixels.filter { level.hole[$0] == 0 }
            guard !ringPixels.isEmpty else { return nil }
            var candidates: [(Int, Int)] = []
            if let previous = best {
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 {
                        candidates.append((previous.x * 2 + dx, previous.y * 2 + dy))
                    }
                }
            } else {
                for ty in -(h - 1) ... (h - 1) {
                    for tx in -(w - 1) ... (w - 1) {
                        candidates.append((tx, ty))
                    }
                }
            }
            var costs = [Float](repeating: .infinity, count: candidates.count)
            costs.withUnsafeMutableBufferPointer { costs in
                level.image.rgb.withUnsafeBufferPointer { px in
                    DispatchQueue.concurrentPerform(iterations: candidates.count) { c in
                        let (tx, ty) = candidates[c]
                        // The whole region must land on known pixels.
                        for p in regionPixels {
                            let x = p % w + tx, y = p / w + ty
                            if x < 0 || y < 0 || x >= w || y >= h || level.hole[y * w + x] != 0 { return }
                        }
                        var sum: Float = 0
                        for p in ringPixels {
                            let q = p + ty * w + tx
                            let dr = px[p * 3] - px[q * 3], dg = px[p * 3 + 1] - px[q * 3 + 1], db = px[p * 3 + 2] - px[q * 3 + 2]
                            sum += dr * dr + dg * dg + db * db
                        }
                        costs[c] = sum
                    }
                }
            }
            guard let winner = costs.indices.min(by: { costs[$0] < costs[$1] }), costs[winner].isFinite else {
                // No room at this level; a finer one can't find any either.
                return nil
            }
            best = (candidates[winner].0, candidates[winner].1)
        }
        guard let offset = best else { return nil }

        // Membrane: the difference between the image and its source, known around the hole,
        // interpolated smoothly across it.
        let w = image.width, h = image.height
        let shift = offset.y * w + offset.x
        var difference = [Float](repeating: 0, count: w * h * 3)
        let around = MaskOps.dilated(hole, width: w, height: h, radius: 1)
        for p in 0 ..< w * h where around[p] != 0 && hole[p] == 0 {
            for channel in 0 ..< 3 {
                difference[p * 3 + channel] = image.rgb[p * 3 + channel] - image.rgb[(p + shift) * 3 + channel]
            }
        }
        // `onionFill` treats everything not flagged as known; pixels outside the ring are zero but
        // never reached, the ring separates them from the hole.
        MaskOps.onionFill(&difference, unknown: hole, width: w, height: h)
        let holePixels = (0 ..< w * h).filter { hole[$0] != 0 }
        let omega: Float = 1.85
        for _ in 0 ..< thickness * 4 + 40 {
            for p in holePixels {
                let x = p % w, y = p / w
                for channel in 0 ..< 3 {
                    var sum: Float = 0
                    var count: Float = 0
                    if x > 0 { sum += difference[(p - 1) * 3 + channel]; count += 1 }
                    if x < w - 1 { sum += difference[(p + 1) * 3 + channel]; count += 1 }
                    if y > 0 { sum += difference[(p - w) * 3 + channel]; count += 1 }
                    if y < h - 1 { sum += difference[(p + w) * 3 + channel]; count += 1 }
                    let current = difference[p * 3 + channel]
                    difference[p * 3 + channel] = current + omega * (sum / count - current)
                }
            }
        }
        var result = image
        for p in holePixels {
            for channel in 0 ..< 3 {
                result.rgb[p * 3 + channel] = image.rgb[(p + shift) * 3 + channel] + difference[p * 3 + channel]
            }
        }
        return (result, offset)
    }
}

// MARK: - Method 2: patch-based fill, coarse to fine

/// Rebuilds the hole from small patches of its surroundings, from a blurry version up to full size
/// (after Wexler, Shechtman and Irani, "Space-Time Completion of Video", 2007): at each scale, every
/// patch that touches the hole looks for the most similar patch outside it, then every hole pixel
/// becomes the weighted average of what the patches covering it propose.
///
/// The patch search is exhaustive at the coarsest scale, then local at the finer ones: around the
/// match inherited from the scale above, plus the matches of the four neighbors shifted by one
/// (coherence, Ashikhmin 2001). No randomized search, on purpose: see the README about PatchMatch.
enum PatchFill {
    static let radius = 3

    struct Level {
        let width: Int
        let height: Int
        var image: Bitmap
        /// How busy the image is around each pixel (`TextureFeatures`), compared along with the
        /// colors and filled in the hole the same way.
        var features: Bitmap
        let hole: [UInt8]
        /// 1 where a patch centered there is whole and outside the hole: a source.
        let source: [UInt8]
        /// Centers of the patches that touch the hole.
        let targets: [Int]
        let holePixels: [Int]
        /// Distance of each pixel to the known area; 0 outside the hole.
        let depth: [Float]
        /// For each target, the index of its source patch's center; -1 elsewhere.
        var match: [Int32]
        var distance: [Float]

        init(image: Bitmap, features: Bitmap, hole: [UInt8]) {
            width = image.width
            height = image.height
            self.image = image
            self.features = features
            self.hole = hole
            let w = image.width, h = image.height, r = PatchFill.radius
            let touched = MaskOps.dilated(hole, width: w, height: h, radius: r)
            var source = [UInt8](repeating: 0, count: w * h)
            var targets: [Int] = []
            if w > 2 * r, h > 2 * r {
                for y in r ..< h - r {
                    for x in r ..< w - r {
                        if touched[y * w + x] != 0 {
                            targets.append(y * w + x)
                        } else {
                            source[y * w + x] = 1
                        }
                    }
                }
            }
            self.source = source
            self.targets = targets
            holePixels = (0 ..< w * h).filter { hole[$0] != 0 }
            depth = MaskOps.depth(hole, width: w, height: h)
            match = [Int32](repeating: -1, count: w * h)
            distance = [Float](repeating: 0, count: w * h)
        }
    }

    struct Timing {
        var levels = 0
        var search: Duration = .zero
        var vote: Duration = .zero
    }

    /// `textureWeight` is how much a difference in texture counts next to a difference in color;
    /// 0 compares colors only.
    static func fill(_ image: Bitmap, hole: [UInt8], textureWeight: Float, timing: inout Timing) -> Bitmap? {
        let pyramid = Pyramid.levels(image, hole: hole, coarsest: 64, minimumShortEdge: 2 * radius + 6)
        timing.levels = pyramid.count
        let clock = ContinuousClock()
        self.textureWeight = textureWeight
        // Measured once at full size over a window as wide as a coarsest pixel, then reduced with
        // the image: at coarse scales, where fine detail has averaged out, it still tells branches
        // from plain sky.
        let texture = TextureFeatures.make(image, hole: hole, window: 1 << (pyramid.count - 1))
        let featurePyramid = Pyramid.levels(texture, hole: hole, coarsest: 64, minimumShortEdge: 2 * radius + 6)

        guard let coarsest = pyramid.last, let coarsestFeatures = featurePyramid.last else { return nil }
        var start = coarsest.image, startFeatures = coarsestFeatures.image
        MaskOps.onionFill(&start.rgb, unknown: coarsest.hole, width: start.width, height: start.height)
        MaskOps.onionFill(&startFeatures.rgb, unknown: coarsest.hole, width: start.width, height: start.height)
        var level = Level(image: start, features: startFeatures, hole: coarsest.hole)
        guard level.source.contains(1) else { return nil }
        for _ in 0 ..< 8 {
            timing.search += clock.measure { search(&level, exhaustive: true) }
            timing.vote += clock.measure { vote(&level, weighted: true, sharp: false) }
        }

        for index in stride(from: pyramid.count - 2, through: 0, by: -1) {
            var finer = Level(image: pyramid[index].image, features: featurePyramid[index].image, hole: pyramid[index].hole)
            guard finer.source.contains(1) else { return nil }
            inherit(from: level, into: &finer)
            // The hole still holds what is being removed: fill it from the inherited matches
            // before any patch is compared.
            timing.vote += clock.measure { vote(&finer, weighted: false, sharp: false) }
            let passes = index == 0 ? 2 : 4
            for pass in 0 ..< passes {
                timing.search += clock.measure { search(&finer, exhaustive: false) }
                timing.vote += clock.measure { vote(&finer, weighted: true, sharp: index == 0 && pass == passes - 1) }
            }
            level = finer
        }
        return level.image
    }

    /// Sum of squared differences between the patches centered on `p` and `q`, given up as soon as
    /// it exceeds `limit`.
    @inline(__always)
    static func patchDistance(_ px: UnsafeBufferPointer<Float>, _ fx: UnsafeBufferPointer<Float>, weight: Float, width: Int, _ p: Int, _ q: Int,
                              limit: Float) -> Float
    {
        var sum: Float = 0
        let span = (2 * radius + 1) * 3
        for dy in -radius ... radius {
            let a = (p + dy * width - radius) * 3, b = (q + dy * width - radius) * 3
            for i in 0 ..< span {
                let d = px[a + i] - px[b + i]
                sum += d * d
            }
            if weight > 0 {
                var texture: Float = 0
                for i in 0 ..< span {
                    let d = fx[a + i] - fx[b + i]
                    texture += d * d
                }
                sum += texture * weight
            }
            if sum >= limit { return sum }
        }
        return sum
    }

    /// Set by `fill`; the prototype runs one fill at a time.
    nonisolated(unsafe) static var textureWeight: Float = 0

    /// Finds a source patch for every target, reading the previous matches (so targets can be
    /// handled in parallel) and the image as currently filled.
    static func search(_ level: inout Level, exhaustive: Bool) {
        let w = level.width, count = level.width * level.height
        let targets = level.targets
        let previous = level.match
        let sources: [Int] = exhaustive ? (0 ..< count).filter { level.source[$0] != 0 } : []
        var match = level.match
        var distance = level.distance
        let source = level.source
        let chunk = 32
        let weight = textureWeight
        let featureValues = level.features.rgb
        level.image.rgb.withUnsafeBufferPointer { px in
          featureValues.withUnsafeBufferPointer { fx in
            match.withUnsafeMutableBufferPointer { match in
                distance.withUnsafeMutableBufferPointer { distance in
                    DispatchQueue.concurrentPerform(iterations: (targets.count + chunk - 1) / chunk) { block in
                        for t in block * chunk ..< min(targets.count, (block + 1) * chunk) {
                            let p = targets[t]
                            var best = Float.infinity
                            var bestSource: Int32 = -1
                            func consider(_ q: Int) {
                                guard q >= 0, q < count, source[q] != 0, Int32(q) != bestSource else { return }
                                let d = patchDistance(px, fx, weight: weight, width: w, p, q, limit: best)
                                if d < best {
                                    best = d
                                    bestSource = Int32(q)
                                }
                            }
                            if exhaustive {
                                for q in sources {
                                    consider(q)
                                }
                            } else {
                                let current = Int(previous[p])
                                if current >= 0 {
                                    consider(current)
                                    for dy in -1 ... 1 {
                                        for dx in -1 ... 1 where dx != 0 || dy != 0 {
                                            consider(current + dy * w + dx)
                                        }
                                    }
                                }
                                for step in [-1, 1, -w, w] {
                                    let neighbor = p + step
                                    if neighbor >= 0, neighbor < count, previous[neighbor] >= 0 {
                                        consider(Int(previous[neighbor]) - step)
                                    }
                                }
                            }
                            if bestSource >= 0 {
                                match[p] = bestSource
                                distance[p] = best
                            }
                        }
                    }
                }
            }
          }
        }
        level.match = match
        level.distance = distance
    }

    /// Sets every hole pixel from the source patches of the targets that cover it. Weights favor
    /// patches that match well and patches close to the hole's edge, which are more reliable.
    /// `sharp` keeps only the best patch's proposal, so the last pass doesn't average texture away.
    static func vote(_ level: inout Level, weighted: Bool, sharp: Bool) {
        let w = level.width, h = level.height, r = radius
        var weights = [Float](repeating: 0, count: w * h)
        var sigma: Float = 1
        if weighted {
            let sorted = level.targets.map { level.distance[$0] }.sorted()
            sigma = max(1e-6, sorted.isEmpty ? 1 : sorted[sorted.count * 3 / 4])
        }
        for p in level.targets where level.match[p] >= 0 {
            let similarity = weighted ? exp(-level.distance[p] / (2 * sigma)) : 1
            weights[p] = max(1e-12, similarity * pow(1.3, -level.depth[p]))
        }
        let holePixels = level.holePixels
        let match = level.match
        let distance = level.distance
        let chunk = 256
        // Taken out of the level while they are written, so nothing is copied.
        var featureValues = level.features.rgb
        level.features.rgb = []
        defer { level.features.rgb = featureValues }
        level.image.rgb.withUnsafeMutableBufferPointer { px in
          featureValues.withUnsafeMutableBufferPointer { fx in
            DispatchQueue.concurrentPerform(iterations: (holePixels.count + chunk - 1) / chunk) { block in
                for i in block * chunk ..< min(holePixels.count, (block + 1) * chunk) {
                    let pixel = holePixels[i]
                    let x = pixel % w, y = pixel / w
                    var sum: (Float, Float, Float) = (0, 0, 0)
                    var texture: (Float, Float) = (0, 0)
                    var total: Float = 0
                    var bestDistance = Float.infinity
                    for dy in -r ... r {
                        let cy = y - dy
                        guard cy >= r, cy < h - r else { continue }
                        for dx in -r ... r {
                            let cx = x - dx
                            guard cx >= r, cx < w - r else { continue }
                            let center = cy * w + cx
                            guard match[center] >= 0 else { continue }
                            // Source patches never touch the hole, so this reads known pixels only
                            // while other threads write hole pixels.
                            let from = (Int(match[center]) + dy * w + dx) * 3
                            if sharp {
                                if distance[center] < bestDistance {
                                    bestDistance = distance[center]
                                    sum = (px[from], px[from + 1], px[from + 2])
                                    texture = (fx[from], fx[from + 1])
                                    total = 1
                                }
                            } else {
                                let weight = weights[center]
                                sum.0 += px[from] * weight; sum.1 += px[from + 1] * weight; sum.2 += px[from + 2] * weight
                                texture.0 += fx[from] * weight; texture.1 += fx[from + 1] * weight
                                total += weight
                            }
                        }
                    }
                    if total > 0 {
                        px[pixel * 3] = sum.0 / total; px[pixel * 3 + 1] = sum.1 / total; px[pixel * 3 + 2] = sum.2 / total
                        fx[pixel * 3] = texture.0 / total; fx[pixel * 3 + 1] = texture.1 / total
                    }
                }
            }
          }
        }
    }

    /// Gives each target of `finer` the match of the target above it, doubled. Where that is not a
    /// source at this scale, the nearest source to it is taken.
    static func inherit(from coarse: Level, into finer: inout Level) {
        let w = finer.width, h = finer.height, r = radius
        for p in finer.targets {
            let x = p % w, y = p / w
            let cx = min(max(x / 2, r), coarse.width - 1 - r), cy = min(max(y / 2, r), coarse.height - 1 - r)
            let above = coarse.match[cy * coarse.width + cx]
            var guess = (x: x, y: y)
            if above >= 0 {
                guess = (Int(above) % coarse.width * 2 + (x - cx * 2), Int(above) / coarse.width * 2 + (y - cy * 2))
            }
            var found: Int32 = -1
            var reach = 0
            while found < 0, reach < max(w, h) {
                var nearest = Int.max
                for qy in max(r, guess.y - reach) ... max(r, min(h - 1 - r, guess.y + reach)) {
                    for qx in max(r, guess.x - reach) ... max(r, min(w - 1 - r, guess.x + reach)) where finer.source[qy * w + qx] != 0 {
                        let d = (qx - guess.x) * (qx - guess.x) + (qy - guess.y) * (qy - guess.y)
                        if d < nearest {
                            nearest = d
                            found = Int32(qy * w + qx)
                        }
                    }
                }
                reach = reach == 0 ? 2 : reach * 2
            }
            finer.match[p] = found
        }
    }
}

/// How much the image varies around each pixel, horizontally and vertically: the mean absolute
/// gradient of the luminance over a window, counting known pixels only (after Newson, Almansa,
/// Gousseau and Pérez, "Non-Local Patch-Based Image Inpainting", 2017). Compared on colors alone,
/// a patch of bare branches against the sky is closer to plain sky than to other branches that
/// don't line up with it, so the fill turns smooth; these two extra channels make "busy" and
/// "plain" different. Stored in the first two channels of a bitmap, the third is unused.
enum TextureFeatures {
    static func make(_ image: Bitmap, hole: [UInt8], window: Int) -> Bitmap {
        let w = image.width, h = image.height
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0 ..< w * h {
            luma[i] = 0.299 * image.rgb[i * 3] + 0.587 * image.rgb[i * 3 + 1] + 0.114 * image.rgb[i * 3 + 2]
        }
        var horizontal = [Float](repeating: 0, count: w * h), vertical = horizontal, known = horizontal
        for y in 0 ..< h {
            for x in 0 ..< w {
                let left = y * w + max(x - 1, 0), right = y * w + min(x + 1, w - 1)
                let up = max(y - 1, 0) * w + x, down = min(y + 1, h - 1) * w + x
                let i = y * w + x
                guard hole[i] == 0, hole[left] == 0, hole[right] == 0, hole[up] == 0, hole[down] == 0 else { continue }
                horizontal[i] = abs(luma[right] - luma[left])
                vertical[i] = abs(luma[down] - luma[up])
                known[i] = 1
            }
        }
        let radius = max(1, window / 2)
        let sumH = boxSum(horizontal, width: w, height: h, radius: radius), sumV = boxSum(vertical, width: w, height: h, radius: radius)
        let count = boxSum(known, width: w, height: h, radius: radius)
        var out = Bitmap(width: w, height: h)
        for i in 0 ..< w * h where count[i] > 0 {
            out.rgb[i * 3] = sumH[i] / count[i]
            out.rgb[i * 3 + 1] = sumV[i] / count[i]
        }
        return out
    }

    /// Sum over the square of `radius` around each entry, by running sums along rows then columns.
    static func boxSum(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var rows = [Float](repeating: 0, count: values.count)
        var prefix = [Float](repeating: 0, count: max(width, height) + 1)
        for y in 0 ..< height {
            for x in 0 ..< width {
                prefix[x + 1] = prefix[x] + values[y * width + x]
            }
            for x in 0 ..< width {
                rows[y * width + x] = prefix[min(width, x + radius + 1)] - prefix[max(0, x - radius)]
            }
        }
        var out = [Float](repeating: 0, count: values.count)
        for x in 0 ..< width {
            for y in 0 ..< height {
                prefix[y + 1] = prefix[y] + rows[y * width + x]
            }
            for y in 0 ..< height {
                out[y * width + x] = prefix[min(height, y + radius + 1)] - prefix[max(0, y - radius)]
            }
        }
        return out
    }
}

// MARK: - Synthetic scenes

/// Procedural test scenes with an object to remove, the mask a user would paint over it and the
/// scene without the object. Deterministic, so runs can be compared.
enum Samples {
    static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Float {
        var h = UInt64(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    static func noise(_ x: Float, _ y: Float, _ seed: Int) -> Float {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(x0, y0, seed), b = hash(x0 + 1, y0, seed), c = hash(x0, y0 + 1, seed), d = hash(x0 + 1, y0 + 1, seed)
        return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
    }

    static func fbm(_ x: Float, _ y: Float, _ seed: Int, octaves: Int = 4) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, fx = x, fy = y
        for octave in 0 ..< octaves {
            sum += amplitude * noise(fx, fy, seed + octave * 17)
            amplitude *= 0.5; fx *= 2; fy *= 2
        }
        return sum / (1 - pow(0.5, Float(octaves)))
    }

    typealias Color = (Float, Float, Float)

    struct Scene {
        let name: String
        let background: (Float, Float) -> Color
        /// The object's color at a pixel, nil outside it.
        let object: (Float, Float) -> Color?
        let mask: (Float, Float) -> Bool
    }

    static func mix(_ a: Color, _ b: Color, _ t: Float) -> Color {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    static func scaled(_ c: Color, _ k: Float) -> Color {
        (c.0 * k, c.1 * k, c.2 * k)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func ellipse(_ x: Float, _ y: Float, _ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float) -> Bool {
        let dx = (x - cx) / rx, dy = (y - cy) / ry
        return dx * dx + dy * dy <= 1
    }

    static func box(_ x: Float, _ y: Float, _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, grow: Float = 0) -> Bool {
        x >= x0 - grow && x <= x1 + grow && y >= y0 - grow && y <= y1 + grow
    }

    /// Distance from a point to the segment a–b.
    static func segment(_ x: Float, _ y: Float, _ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) -> Float {
        let vx = bx - ax, vy = by - ay
        let t = max(0, min(1, ((x - ax) * vx + (y - ay) * vy) / (vx * vx + vy * vy)))
        return hypot(x - ax - t * vx, y - ay - t * vy)
    }

    static let width = 1200, height = 900

    static func sky(_ seed: Int) -> (Float, Float) -> Color {
        { x, y in
            let base = mix((0.22, 0.42, 0.78), (0.66, 0.80, 0.94), y / Float(height))
            let cloud = smoothstep(0.48, 0.72, fbm(x / 260, y / 130, seed, octaves: 5))
            return mix(base, (0.97, 0.97, 0.96), cloud * 0.9)
        }
    }

    static let scenes: [Scene] = [
        Scene(name: "sky-bird", background: sky(3),
              object: { x, y in
                  ellipse(x, y, 700, 300, 26, 11) || ellipse(x, y, 684, 290, 22, 5) || ellipse(x, y, 716, 290, 22, 5) ? (0.08, 0.08, 0.1) : nil
              },
              mask: { x, y in ellipse(x, y, 700, 296, 56, 28) }),
        Scene(name: "sky-wire", background: sky(11),
              object: { x, y in segment(x, y, -10, 210, 1210, 340) < 1.6 ? (0.1, 0.1, 0.12) : nil },
              mask: { x, y in segment(x, y, -10, 210, 1210, 340) < 8 }),
        Scene(name: "grass-ball",
              background: { x, y in
                  let blades = fbm(x / 3, y / 14, 5, octaves: 3)
                  let patches = fbm(x / 180, y / 180, 6)
                  return scaled(mix((0.16, 0.40, 0.10), (0.36, 0.55, 0.16), patches), 0.55 + 0.9 * blades)
              },
              object: { x, y in
                  if ellipse(x, y, 600, 480, 60, 60) {
                      let light = 1.15 - hypot(x - 580, y - 455) / 110
                      return scaled((0.85, 0.12, 0.1), max(0.35, light))
                  }
                  return nil
              },
              mask: { x, y in ellipse(x, y, 600, 484, 74, 78) }),
        Scene(name: "bricks-sign",
              background: { x, y in
                  let row = Int(floor(y / 40))
                  let shifted = x + (row % 2 == 0 ? 0 : 45)
                  let column = Int(floor(shifted / 90))
                  let inMortar = y - Float(row) * 40 < 5 || shifted - Float(column) * 90 < 5
                  let light = 0.8 + 0.3 * x / Float(width)
                  if inMortar { return scaled((0.72, 0.70, 0.66), light) }
                  let tone = hash(column, row, 21)
                  return scaled(mix((0.55, 0.22, 0.15), (0.72, 0.34, 0.22), tone), light * (0.9 + 0.2 * fbm(x / 6, y / 6, 22, octaves: 2)))
              },
              object: { x, y in box(x, y, 520, 390, 680, 500) ? (box(x, y, 530, 400, 670, 490) ? (0.9, 0.9, 0.85) : (0.2, 0.2, 0.22)) : nil },
              mask: { x, y in box(x, y, 520, 390, 680, 500, grow: 8) }),
        Scene(name: "horizon-boat",
              background: { x, y in
                  if y < 400 { return mix((0.45, 0.62, 0.88), (0.82, 0.88, 0.94), y / 400) }
                  let waves = fbm(x / 45, y / 5, 31, octaves: 3)
                  return scaled((0.10, 0.30, 0.46), 0.65 + 0.7 * waves)
              },
              object: { x, y in
                  box(x, y, 540, 385, 660, 420) || box(x, y, 596, 290, 604, 385) ? (0.15, 0.1, 0.08) : nil
              },
              mask: { x, y in box(x, y, 540, 385, 660, 420, grow: 9) || box(x, y, 596, 290, 604, 385, grow: 9) }),
        Scene(name: "sand-towel",
              background: { x, y in
                  let ripple = sin(x * 0.05 + y * 0.25 + 6 * fbm(x / 150, y / 150, 41))
                  return scaled((0.86, 0.76, 0.58), 0.82 + 0.09 * ripple + 0.08 * fbm(x / 2, y / 2, 42, octaves: 2))
              },
              object: { x, y in
                  box(x, y, 440, 330, 760, 570) ? (Int(x / 40) % 2 == 0 ? (0.15, 0.35, 0.75) : (0.92, 0.92, 0.9)) : nil
              },
              mask: { x, y in box(x, y, 440, 330, 760, 570, grow: 10) }),
    ]

    static func write(to folder: URL) {
        for scene in scenes {
            var image = Bitmap(width: width, height: height), truth = image
            var mask = [UInt8](repeating: 0, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let fx = Float(x), fy = Float(y)
                    // Sensor-like noise, so a fill that is too smooth shows.
                    let grain = (hash(x, y, 99) + hash(x, y, 98) - 1) * 0.03
                    let back = scene.background(fx, fy)
                    let front = scene.object(fx, fy) ?? back
                    let i = (y * width + x) * 3
                    truth.rgb[i] = back.0 + grain; truth.rgb[i + 1] = back.1 + grain; truth.rgb[i + 2] = back.2 + grain
                    image.rgb[i] = front.0 + grain; image.rgb[i + 1] = front.1 + grain; image.rgb[i + 2] = front.2 + grain
                    mask[y * width + x] = scene.mask(fx, fy) ? 1 : 0
                }
            }
            ImageFile.save(image, to: folder.appending(path: "\(scene.name).png"))
            ImageFile.save(truth, to: folder.appending(path: "\(scene.name)-truth.png"))
            ImageFile.save(mask: mask, width: width, height: height, to: folder.appending(path: "\(scene.name)-mask.png"))
        }
        print("Wrote \(scenes.count) scenes to \(folder.path)")
    }
}

// MARK: - Contact sheet

/// The area around the hole from several images, side by side (stacked for a wide area), to compare
/// the methods at a glance.
enum Sheet {
    static func save(_ tiles: [Bitmap], view: Rect, to url: URL) {
        let stacked = view.width > view.height * 2
        let scale = min(2, stacked ? 1200 / CGFloat(view.width) : min(520 / CGFloat(view.width), 520 / CGFloat(view.height)))
        let tileWidth = Int(CGFloat(view.width) * scale), tileHeight = Int(CGFloat(view.height) * scale), gap = 6
        let count = tiles.count
        let width = stacked ? tileWidth : tileWidth * count + gap * (count - 1)
        let height = stacked ? tileHeight * count + gap * (count - 1) : tileHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: ImageFile.space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, tile) in tiles.enumerated() {
            guard let image = ImageFile.cgImage(tile.cropped(to: view)) else { continue }
            let x = stacked ? 0 : index * (tileWidth + gap)
            let y = stacked ? height - tileHeight - index * (tileHeight + gap) : 0
            context.draw(image, in: CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
        }
        if let image = context.makeImage() {
            ImageFile.save(image, to: url)
        }
    }
}

// MARK: - Command line

func milliseconds(_ duration: Duration) -> String {
    String(format: "%.0f ms", Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
}

/// Paints discs into a mask. Coordinates are fractions of the width and height from the top left,
/// the radius a fraction of the long edge, as the app's brush strokes are stored.
func paint(dabs: [(x: Double, y: Double, radius: Double)], width: Int, height: Int) -> [UInt8] {
    var mask = [UInt8](repeating: 0, count: width * height)
    for dab in dabs {
        let cx = dab.x * Double(width), cy = dab.y * Double(height), r = dab.radius * Double(max(width, height))
        guard Int(cy - r) <= Int(cy + r) else { continue }
        for y in max(0, Int(cy - r)) ... min(height - 1, Int(cy + r)) {
            for x in max(0, Int(cx - r)) ... min(width - 1, Int(cx + r)) where hypot(Double(x) - cx, Double(y) - cy) <= r {
                mask[y * width + x] = 1
            }
        }
    }
    return mask
}

func runFill(arguments: [String]) {
    guard arguments.count >= 3 else {
        print("usage: heal fill <image> <out dir> (--mask <png> | --dab x,y,r … | --stroke x1,y1,x2,y2,r …) [--truth <png>] [--reach 4] [--texture 0]")
        exit(2)
    }
    let imageURL = URL(fileURLWithPath: arguments[0]), outFolder = URL(fileURLWithPath: arguments[1])
    guard let image = ImageFile.load(imageURL) else {
        print("Can't read \(imageURL.path)")
        exit(1)
    }
    let w = image.width, h = image.height
    var mask: [UInt8]?
    var dabs: [(x: Double, y: Double, radius: Double)] = []
    var truth: Bitmap?
    var reach = 4.0
    // Off by default: on the real photos tried it did not help, see the README.
    var textureWeight = 0.0
    var index = 2
    while index + 1 < arguments.count {
        let value = arguments[index + 1]
        let numbers = value.split(separator: ",").compactMap { Double($0) }
        switch arguments[index] {
        case "--mask": mask = ImageFile.loadMask(URL(fileURLWithPath: value), width: w, height: h)
        case "--truth": truth = ImageFile.load(URL(fileURLWithPath: value))
        case "--reach" where numbers.count == 1: reach = numbers[0]
        case "--texture" where numbers.count == 1: textureWeight = numbers[0]
        case "--dab" where numbers.count == 3: dabs.append((numbers[0], numbers[1], numbers[2]))
        case "--stroke" where numbers.count == 5:
            let length = hypot((numbers[2] - numbers[0]) * Double(w), (numbers[3] - numbers[1]) * Double(h))
            let steps = max(1, Int(length / max(1, numbers[4] * Double(max(w, h)) * 0.25)))
            for step in 0 ... steps {
                let t = Double(step) / Double(steps)
                dabs.append((numbers[0] + (numbers[2] - numbers[0]) * t, numbers[1] + (numbers[3] - numbers[1]) * t, numbers[4]))
            }
        default:
            print("Unknown option \(arguments[index]) \(value)")
            exit(2)
        }
        index += 2
    }
    let hole = mask ?? paint(dabs: dabs, width: w, height: h)
    guard let bounds = MaskOps.bounds(hole, width: w, height: h) else {
        print("Nothing to remove")
        exit(1)
    }

    // Work on the hole's surroundings only: wide enough to find material, small enough to stay fast
    // and to keep what is copied at the scale and light of the place (`--reach`, in hole thicknesses).
    let thickness = Int(MaskOps.depth(hole, width: w, height: h).max() ?? 1)
    let margin = min(600, max(48, Int(Double(thickness) * reach)))
    let x0 = max(0, bounds.x - margin), y0 = max(0, bounds.y - margin)
    let x1 = min(w, bounds.x + bounds.width + margin), y1 = min(h, bounds.y + bounds.height + margin)
    let work = Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    let crop = image.cropped(to: work), cropHole = MaskOps.cropped(hole, width: w, to: work)
    let name = imageURL.deletingPathExtension().lastPathComponent
    let holeCount = hole.reduce(0) { $0 + Int($1) }
    print("\(name): \(w)x\(h), hole \(bounds.width)x\(bounds.height) (\(holeCount) px, thickness \(thickness)), work area \(work.width)x\(work.height)")

    let clock = ContinuousClock()
    // The painted region in red over the original, to check where the strokes landed.
    var overlay = image
    for p in 0 ..< w * h where hole[p] != 0 {
        overlay.rgb[p * 3] = overlay.rgb[p * 3] * 0.45 + 0.55
        overlay.rgb[p * 3 + 1] *= 0.45
        overlay.rgb[p * 3 + 2] *= 0.45
    }
    ImageFile.save(overlay, to: outFolder.appending(path: "\(name)-mask.png"))
    var tiles = [image, overlay]

    var healed: (result: Bitmap, offset: (x: Int, y: Int))?
    let healTime = clock.measure { healed = SourceHeal.fill(crop, hole: cropHole, thickness: thickness) }
    if let healed {
        var out = image
        out.paste(healed.result, at: work, where: cropHole)
        ImageFile.save(out, to: outFolder.appending(path: "\(name)-source.png"))
        tiles.append(out)
        print("  source heal: \(milliseconds(healTime)), source at (\(healed.offset.x), \(healed.offset.y))")
    } else {
        print("  source heal: no area of that shape to copy from (\(milliseconds(healTime)))")
    }

    var timing = PatchFill.Timing()
    var filled: Bitmap?
    let fillTime = clock.measure { filled = PatchFill.fill(crop, hole: cropHole, textureWeight: Float(textureWeight), timing: &timing) }
    if let filled {
        var out = image
        out.paste(filled, at: work, where: cropHole)
        ImageFile.save(out, to: outFolder.appending(path: "\(name)-patch.png"))
        tiles.append(out)
        print("  patch fill: \(milliseconds(fillTime)) over \(timing.levels) scales (search \(milliseconds(timing.search)), vote \(milliseconds(timing.vote)))")
    } else {
        print("  patch fill: no source patches around the hole")
    }
    if let truth, truth.width == w, truth.height == h {
        tiles.append(truth)
    }

    let pad = max(60, max(bounds.width, bounds.height) * 3 / 4)
    let vx0 = max(0, bounds.x - pad), vy0 = max(0, bounds.y - pad)
    let view = Rect(x: vx0, y: vy0, width: min(w, bounds.x + bounds.width + pad) - vx0, height: min(h, bounds.y + bounds.height + pad) - vy0)
    Sheet.save(tiles, view: view, to: outFolder.appending(path: "\(name)-sheet.png"))
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "samples" where arguments.count == 2:
    Samples.write(to: URL(fileURLWithPath: arguments[1]))
case "fill":
    runFill(arguments: Array(arguments.dropFirst()))
default:
    print("""
    usage: heal samples <dir>
           heal fill <image> <out dir> (--mask <png> | --dab x,y,r … | --stroke x1,y1,x2,y2,r …) [--truth <png>] [--reach 4] [--texture 0]
    """)
    exit(2)
}
