import Foundation
@testable import HealingFill
import Testing

struct PatchFillTests {
    /// A blue-to-white vertical gradient with a little deterministic grain, and a red square on it.
    private func scene(width: Int, height: Int, square: ClosedRange<Int>) -> (image: FillBitmap, hole: [UInt8]) {
        var image = FillBitmap(width: width, height: height)
        var hole = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let t = Float(y) / Float(height), grain = Float((x &* 7919 &+ y &* 104_729) % 13) / 13 * 0.03
                let i = (y * width + x) * 3
                if square.contains(x), square.contains(y) {
                    image.rgb[i] = 1; image.rgb[i + 1] = 0; image.rgb[i + 2] = 0
                } else {
                    image.rgb[i] = 0.2 + 0.6 * t + grain; image.rgb[i + 1] = 0.4 + 0.5 * t + grain; image.rgb[i + 2] = 0.9
                }
                // Painted a little wider than the square, as a brush would.
                if x >= square.lowerBound - 3, x <= square.upperBound + 3, y >= square.lowerBound - 3, y <= square.upperBound + 3 {
                    hole[y * width + x] = 1
                }
            }
        }
        return (image, hole)
    }

    @Test func fillsTheHoleFromItsSurroundingsAndLeavesTheRestAlone() throws {
        let (image, hole) = scene(width: 160, height: 160, square: 60 ... 90)
        let filled = try #require(PatchFill.fill(image, hole: hole))
        // One expectation for all pixels: the macro is too slow to run tens of thousands of times.
        var changedOutside = 0, leftOfTheSquare = 0
        for index in hole.indices {
            let i = index * 3
            if hole[index] == 0 {
                changedOutside += filled.rgb[i] == image.rgb[i] && filled.rgb[i + 1] == image.rgb[i + 1] && filled.rgb[i + 2] == image.rgb[i + 2] ? 0 : 1
            } else {
                // The gradient is at most 0.83 red with at least 0.4 green: the square is neither.
                leftOfTheSquare += filled.rgb[i] < 0.9 && filled.rgb[i + 1] > 0.35 && filled.rgb[i + 2] > 0.85 ? 0 : 1
            }
        }
        #expect(changedOutside == 0, "known pixels are untouched")
        #expect(leftOfTheSquare == 0, "nothing of the square is left")
        // The gradient continues through the hole: its middle row sits between the rows above and below.
        let middle = filled.rgb[(75 * 160 + 75) * 3]
        #expect(abs(middle - (0.2 + 0.6 * 75 / 160)) < 0.08)
    }

    @Test func theSameInputGivesTheSameFill() throws {
        let (image, hole) = scene(width: 120, height: 100, square: 40 ... 60)
        let first = try #require(PatchFill.fill(image, hole: hole))
        let second = try #require(PatchFill.fill(image, hole: hole))
        #expect(first == second)
    }

    @Test func aHoleWithNothingAroundCantBeFilled() {
        let image = FillBitmap(width: 40, height: 40)
        #expect(PatchFill.fill(image, hole: [UInt8](repeating: 1, count: 1600)) == nil)
        let tiny = FillBitmap(width: 5, height: 5)
        var hole = [UInt8](repeating: 0, count: 25)
        hole[12] = 1
        #expect(PatchFill.fill(tiny, hole: hole) == nil, "smaller than a patch")
    }

    /// A thin region in a narrow area: halved down to 64 pixels, the hole would leave no room for a
    /// single source patch beside it.
    @Test func aThinRegionInANarrowAreaStillFindsMaterial() throws {
        let width = 246, height = 658
        var image = FillBitmap(width: width, height: height)
        var hole = [UInt8](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 3
                image.rgb[i] = 0.3 + 0.4 * Float(y) / Float(height); image.rgb[i + 1] = 0.5; image.rgb[i + 2] = 0.9
                // A band 32 pixels wide leaning across the area, like a pole.
                let center = 110 + (y - 93) * 26 / 472
                if (93 ..< 565).contains(y), abs(x - center) <= 16 {
                    image.rgb[i] = 1; image.rgb[i + 1] = 0; image.rgb[i + 2] = 0
                    hole[y * width + x] = 1
                }
            }
        }
        #expect(PatchFill.patchCensus(hole, width: width, height: height).sources > 0)
        let filled = try #require(PatchFill.fill(image, hole: hole))
        var leftOfTheBand = 0
        for index in hole.indices where hole[index] != 0 {
            leftOfTheBand += filled.rgb[index * 3] < 0.8 && filled.rgb[index * 3 + 2] > 0.8 ? 0 : 1
        }
        #expect(leftOfTheBand == 0)
    }

    @Test func helpersMeasureTheHole() {
        var mask = [UInt8](repeating: 0, count: 81)
        mask[4 * 9 + 4] = 1
        let grown = PatchFill.dilated(mask, width: 9, height: 9, radius: 2)
        #expect(grown.reduce(0) { $0 + Int($1) } == 25)
        #expect(grown[2 * 9 + 2] == 1 && grown[1 * 9 + 4] == 0)
        let depth = PatchFill.depth(grown, width: 9, height: 9)
        #expect(depth[4 * 9 + 4] == 3 && depth[2 * 9 + 4] == 1 && depth[0] == 0)
    }

    /// Not a correctness test: reports how long a fill of a realistic size takes in this build.
    @Test func reportsItsDuration() {
        let (image, hole) = scene(width: 700, height: 700, square: 280 ... 420)
        let clock = ContinuousClock()
        var filled: FillBitmap?
        let duration = clock.measure { filled = PatchFill.fill(image, hole: hole) }
        #expect(filled != nil)
        print("PatchFill 700x700, hole 147x147: \(duration)")
    }
}
