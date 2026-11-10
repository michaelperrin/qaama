import Dispatch
import Foundation

/// A rectangle of RGB pixels as floats, row-major, top row first: what the fill works on.
package struct FillBitmap: Equatable, Sendable {
    package let width: Int
    package let height: Int
    /// Three values per pixel.
    package var rgb: [Float]

    package init(width: Int, height: Int, rgb: [Float]? = nil) {
        self.width = width
        self.height = height
        self.rgb = rgb ?? [Float](repeating: 0, count: width * height * 3)
    }
}

/// Fills a hole in an image from small patches of its surroundings, from a blurry version up to full
/// size (after Wexler, Shechtman and Irani, "Space-Time Completion of Video", 2007): at each scale,
/// every patch that touches the hole looks for the most similar patch outside it, then every hole
/// pixel becomes the weighted average of what the patches covering it propose. The last pass keeps
/// the best proposal only, so texture and grain stay sharp.
///
/// The patch search is exhaustive at the coarsest scale, then local at the finer ones: around the
/// match inherited from the scale above, plus the matches of the four neighbors shifted by one
/// (coherence, Ashikhmin 2001). No randomized search, on purpose: PatchMatch is patented until
/// about 2029 (see `Experiments/heal/README.md`, which also has the measurements behind this).
///
/// Pure and deterministic: the same pixels and hole give the same fill, whatever the thread count,
/// because every pass reads the previous pass's matches and writes its own. Blocking and
/// multithreaded; call it off the main actor.
///
/// In a target of its own, always compiled with optimization: see `Package.swift`.
package enum PatchFill {
    /// Half-width of a patch: patches are 7 × 7.
    static let radius = 3
    /// Long edge, in pixels, under which a scale is coarse enough to start from.
    static let coarsestLongEdge = 64
    /// Most pairs of patches the exhaustive search of the coarsest scale may have to compare.
    static let exhaustivePairs = 2_000_000

    /// The image with the pixels flagged in `hole` (1 = to fill, same size as the image) rebuilt.
    /// Nil when nothing around the hole can serve as material: it covers the image, or the image is
    /// smaller than a patch.
    package static func fill(_ image: FillBitmap, hole: [UInt8]) -> FillBitmap? {
        precondition(hole.count == image.width * image.height)
        // Halve until the image is small enough to search exhaustively. The hole thickens at each
        // halving while the room around it shrinks: a thin region in a narrow area runs out of
        // source patches before it is small, and stops at the last scale that has more material
        // than hole, if that one is affordable.
        var pyramid = [(image: image, hole: hole)]
        var census = patchCensus(hole, width: image.width, height: image.height)
        while let last = pyramid.last, max(last.image.width, last.image.height) > coarsestLongEdge,
              (min(last.image.width, last.image.height) + 1) / 2 >= 2 * radius + 6
        {
            let next = halved(last.image, hole: last.hole)
            let nextCensus = patchCensus(next.hole, width: next.image.width, height: next.image.height)
            if nextCensus.sources == 0 || (nextCensus.sources < nextCensus.targets && census.sources * census.targets <= exhaustivePairs) {
                break
            }
            pyramid.append(next)
            census = nextCensus
        }

        guard let coarsest = pyramid.last else { return nil }
        var start = coarsest.image
        onionFill(&start.rgb, unknown: coarsest.hole, width: start.width, height: start.height)
        var level = Level(image: start, hole: coarsest.hole)
        guard level.hasSources else { return nil }
        for _ in 0 ..< 8 {
            search(&level, exhaustive: true)
            vote(&level, weighted: true, sharp: false)
        }

        for index in stride(from: pyramid.count - 2, through: 0, by: -1) {
            var finer = Level(image: pyramid[index].image, hole: pyramid[index].hole)
            guard finer.hasSources else { return nil }
            inherit(from: level, into: &finer)
            // The hole still holds what is being removed: fill it from the inherited matches before
            // any patch is compared.
            vote(&finer, weighted: false, sharp: false)
            let passes = index == 0 ? 2 : 4
            for pass in 0 ..< passes {
                search(&finer, exhaustive: false)
                vote(&finer, weighted: true, sharp: index == 0 && pass == passes - 1)
            }
            level = finer
        }
        return level.image
    }

    // MARK: - One scale

    struct Level {
        let width: Int
        let height: Int
        var image: FillBitmap
        /// 1 where a patch centered there is whole and outside the hole: a source.
        let source: [UInt8]
        let hasSources: Bool
        /// Centers of the patches that touch the hole.
        let targets: [Int]
        let holePixels: [Int]
        /// Distance of each pixel to the known area; 0 outside the hole.
        let depth: [Float]
        /// For each target, the index of its source patch's center; -1 elsewhere.
        var match: [Int32]
        var distance: [Float]

        init(image: FillBitmap, hole: [UInt8]) {
            width = image.width
            height = image.height
            self.image = image
            let w = image.width, h = image.height, r = PatchFill.radius
            let touched = dilated(hole, width: w, height: h, radius: r)
            var source = [UInt8](repeating: 0, count: w * h)
            var targets: [Int] = []
            var hasSources = false
            if w > 2 * r, h > 2 * r {
                for y in r ..< h - r {
                    for x in r ..< w - r {
                        if touched[y * w + x] != 0 {
                            targets.append(y * w + x)
                        } else {
                            source[y * w + x] = 1
                            hasSources = true
                        }
                    }
                }
            }
            self.source = source
            self.hasSources = hasSources
            self.targets = targets
            holePixels = hole.indices.filter { hole[$0] != 0 }
            depth = PatchFill.depth(hole, width: w, height: h)
            match = [Int32](repeating: -1, count: w * h)
            distance = [Float](repeating: 0, count: w * h)
        }
    }

    /// How many patches of an image lie whole outside the hole (sources) and how many touch it
    /// (targets), as `Level` will count them.
    static func patchCensus(_ hole: [UInt8], width: Int, height: Int) -> (sources: Int, targets: Int) {
        guard width > 2 * radius, height > 2 * radius else { return (0, 0) }
        let touched = dilated(hole, width: width, height: height, radius: radius)
        var targets = 0
        for y in radius ..< height - radius {
            for x in radius ..< width - radius where touched[y * width + x] != 0 {
                targets += 1
            }
        }
        return ((width - 2 * radius) * (height - 2 * radius) - targets, targets)
    }

    /// Sum of squared differences between the patches centered on `p` and `q`, given up as soon as
    /// it reaches `limit`.
    @inline(__always)
    private static func patchDistance(_ px: UnsafePointer<Float>, width: Int, _ p: Int, _ q: Int, limit: Float) -> Float {
        var sum: Float = 0
        let span = (2 * radius + 1) * 3
        var a = px + (p - radius * width - radius) * 3, b = px + (q - radius * width - radius) * 3
        for _ in 0 ... 2 * radius {
            for i in 0 ..< span {
                let d = a[i] - b[i]
                sum += d * d
            }
            if sum >= limit {
                return sum
            }
            a += width * 3
            b += width * 3
        }
        return sum
    }

    /// Finds a source patch for every target, reading the previous matches (so targets can be
    /// handled in parallel, in any order) and the image as currently filled.
    static func search(_ level: inout Level, exhaustive: Bool) {
        let w = level.width, count = level.width * level.height
        let targets = level.targets
        let previous = level.match
        let sources: [Int] = exhaustive ? level.source.indices.filter { level.source[$0] != 0 } : []
        var match = level.match
        var distance = level.distance
        let chunk = 32
        level.image.rgb.withUnsafeBufferPointer { pixels in
            level.source.withUnsafeBufferPointer { source in
                previous.withUnsafeBufferPointer { previous in
                    match.withUnsafeMutableBufferPointer { match in
                        distance.withUnsafeMutableBufferPointer { distance in
                            guard let px = pixels.baseAddress, let source = source.baseAddress, let previous = previous.baseAddress,
                                  let match = match.baseAddress, let distance = distance.baseAddress else { return }
                            // The pointers are only read, or written at indices no other block touches.
                            nonisolated(unsafe) let shared = (px: px, source: source, previous: previous, match: match, distance: distance)
                            DispatchQueue.concurrentPerform(iterations: (targets.count + chunk - 1) / chunk) { block in
                                for t in block * chunk ..< min(targets.count, (block + 1) * chunk) {
                                    let p = targets[t]
                                    var best = Float.infinity
                                    var bestSource = -1
                                    var candidates: [Int] = []
                                    if exhaustive {
                                        for q in sources {
                                            let d = patchDistance(shared.px, width: w, p, q, limit: best)
                                            if d < best {
                                                best = d
                                                bestSource = q
                                            }
                                        }
                                    } else {
                                        candidates.reserveCapacity(13)
                                        let current = Int(shared.previous[p])
                                        if current >= 0 {
                                            candidates.append(current)
                                            for dy in -1 ... 1 {
                                                for dx in -1 ... 1 where dx != 0 || dy != 0 {
                                                    candidates.append(current + dy * w + dx)
                                                }
                                            }
                                        }
                                        for step in [-1, 1, -w, w] {
                                            let neighbor = p + step
                                            if neighbor >= 0, neighbor < count, shared.previous[neighbor] >= 0 {
                                                candidates.append(Int(shared.previous[neighbor]) - step)
                                            }
                                        }
                                        for q in candidates where q >= 0 && q < count && shared.source[q] != 0 && q != bestSource {
                                            let d = patchDistance(shared.px, width: w, p, q, limit: best)
                                            if d < best {
                                                best = d
                                                bestSource = q
                                            }
                                        }
                                    }
                                    if bestSource >= 0 {
                                        shared.match[p] = Int32(bestSource)
                                        shared.distance[p] = best
                                    }
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
        let chunk = 256
        level.match.withUnsafeBufferPointer { match in
            level.distance.withUnsafeBufferPointer { distance in
                weights.withUnsafeBufferPointer { weights in
                    level.image.rgb.withUnsafeMutableBufferPointer { pixels in
                        guard let px = pixels.baseAddress, let match = match.baseAddress, let distance = distance.baseAddress,
                              let weights = weights.baseAddress else { return }
                        // Source patches never touch the hole, so blocks read known pixels only
                        // while each writes its own hole pixels.
                        nonisolated(unsafe) let shared = (px: px, match: match, distance: distance, weights: weights)
                        DispatchQueue.concurrentPerform(iterations: (holePixels.count + chunk - 1) / chunk) { block in
                            for i in block * chunk ..< min(holePixels.count, (block + 1) * chunk) {
                                let pixel = holePixels[i]
                                let x = pixel % w, y = pixel / w
                                var red: Float = 0, green: Float = 0, blue: Float = 0, total: Float = 0
                                var bestDistance = Float.infinity
                                for dy in max(-r, y - (h - r - 1)) ... min(r, y - r) {
                                    for dx in max(-r, x - (w - r - 1)) ... min(r, x - r) {
                                        let center = (y - dy) * w + x - dx
                                        let source = Int(shared.match[center])
                                        guard source >= 0 else { continue }
                                        let from = shared.px + (source + dy * w + dx) * 3
                                        if sharp {
                                            if shared.distance[center] < bestDistance {
                                                bestDistance = shared.distance[center]
                                                red = from[0]; green = from[1]; blue = from[2]
                                                total = 1
                                            }
                                        } else {
                                            let weight = shared.weights[center]
                                            red += from[0] * weight; green += from[1] * weight; blue += from[2] * weight
                                            total += weight
                                        }
                                    }
                                }
                                if total > 0 {
                                    let to = shared.px + pixel * 3
                                    to[0] = red / total; to[1] = green / total; to[2] = blue / total
                                }
                            }
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
            while found < 0, reach < 2 * max(w, h) {
                var nearest = Int.max
                let rows = max(r, guess.y - reach) ... max(r, min(h - 1 - r, guess.y + reach))
                let columns = max(r, guess.x - reach) ... max(r, min(w - 1 - r, guess.x + reach))
                for qy in rows {
                    for qx in columns where finer.source[qy * w + qx] != 0 {
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

    // MARK: - Helpers

    /// A half-size copy of an image and its hole. A coarse pixel is a hole as soon as one of its
    /// four pixels is, so known coarse pixels never mix in what is being removed.
    static func halved(_ image: FillBitmap, hole: [UInt8]) -> (image: FillBitmap, hole: [UInt8]) {
        let w = (image.width + 1) / 2, h = (image.height + 1) / 2
        var out = FillBitmap(width: w, height: h)
        var outHole = [UInt8](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var red: Float = 0, green: Float = 0, blue: Float = 0
                var isHole: UInt8 = 0
                for dy in 0 ... 1 {
                    for dx in 0 ... 1 {
                        let s = min(image.height - 1, y * 2 + dy) * image.width + min(image.width - 1, x * 2 + dx)
                        red += image.rgb[s * 3]; green += image.rgb[s * 3 + 1]; blue += image.rgb[s * 3 + 2]
                        isHole |= hole[s]
                    }
                }
                let o = (y * w + x) * 3
                out.rgb[o] = red / 4; out.rgb[o + 1] = green / 4; out.rgb[o + 2] = blue / 4
                outHole[y * w + x] = isHole
            }
        }
        return (out, outHole)
    }

    /// Box dilation by `radius` pixels, in two passes.
    package static func dilated(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return mask }
        var rows = [UInt8](repeating: 0, count: mask.count)
        for y in 0 ..< height {
            // Distance to the last set pixel on the left, then on the right.
            var since = radius + 1
            for x in 0 ..< width {
                since = mask[y * width + x] != 0 ? 0 : since + 1
                if since <= radius {
                    rows[y * width + x] = 1
                }
            }
            since = radius + 1
            for x in stride(from: width - 1, through: 0, by: -1) {
                since = mask[y * width + x] != 0 ? 0 : since + 1
                if since <= radius {
                    rows[y * width + x] = 1
                }
            }
        }
        var out = [UInt8](repeating: 0, count: mask.count)
        for x in 0 ..< width {
            var since = radius + 1
            for y in 0 ..< height {
                since = rows[y * width + x] != 0 ? 0 : since + 1
                if since <= radius {
                    out[y * width + x] = 1
                }
            }
            since = radius + 1
            for y in stride(from: height - 1, through: 0, by: -1) {
                since = rows[y * width + x] != 0 ? 0 : since + 1
                if since <= radius {
                    out[y * width + x] = 1
                }
            }
        }
        return out
    }

    /// For each masked pixel, its approximate distance to the nearest unmasked one (chamfer 3-4).
    package static func depth(_ mask: [UInt8], width: Int, height: Int) -> [Float] {
        let far: Float = 1e9, diagonal: Float = 4.0 / 3
        var d = mask.map { $0 != 0 ? far : 0 }
        for y in 0 ..< height {
            for x in 0 ..< width where d[y * width + x] > 0 {
                let i = y * width + x
                var best = d[i]
                if x > 0 {
                    best = min(best, d[i - 1] + 1)
                }
                if y > 0 {
                    best = min(best, d[i - width] + 1)
                    if x > 0 {
                        best = min(best, d[i - width - 1] + diagonal)
                    }
                    if x < width - 1 {
                        best = min(best, d[i - width + 1] + diagonal)
                    }
                }
                d[i] = best
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) where d[y * width + x] > 0 {
                let i = y * width + x
                var best = d[i]
                if x < width - 1 {
                    best = min(best, d[i + 1] + 1)
                }
                if y < height - 1 {
                    best = min(best, d[i + width] + 1)
                    if x < width - 1 {
                        best = min(best, d[i + width + 1] + diagonal)
                    }
                    if x > 0 {
                        best = min(best, d[i + width - 1] + diagonal)
                    }
                }
                d[i] = best
            }
        }
        return d
    }

    /// Fills the unknown pixels from the known ones around, ring by ring: a smooth first guess.
    static func onionFill(_ values: inout [Float], unknown: [UInt8], width: Int, height: Int) {
        var pending = unknown
        var frontier = pending.indices.filter { pending[$0] != 0 }
        while !frontier.isEmpty {
            var filled: [(index: Int, red: Float, green: Float, blue: Float)] = []
            var rest: [Int] = []
            for index in frontier {
                let x = index % width, y = index / width
                var red: Float = 0, green: Float = 0, blue: Float = 0, count: Float = 0
                for ny in max(0, y - 1) ... min(height - 1, y + 1) {
                    for nx in max(0, x - 1) ... min(width - 1, x + 1) where pending[ny * width + nx] == 0 {
                        let n = (ny * width + nx) * 3
                        red += values[n]; green += values[n + 1]; blue += values[n + 2]
                        count += 1
                    }
                }
                if count > 0 {
                    filled.append((index, red / count, green / count, blue / count))
                } else {
                    rest.append(index)
                }
            }
            guard !filled.isEmpty else { return }
            for entry in filled {
                values[entry.index * 3] = entry.red; values[entry.index * 3 + 1] = entry.green; values[entry.index * 3 + 2] = entry.blue
                pending[entry.index] = 0
            }
            frontier = rest
        }
    }
}
