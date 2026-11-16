import CubeLUT
import Foundation
import Testing

/// The text of a `.cube` file for a transform of 0…1 colors, as LUT tools write it.
func cubeFileText(dimension: Int, header: String = "", transform: (Float, Float, Float) -> (Float, Float, Float) = { ($0, $1, $2) }) -> String {
    var lines = [header, "LUT_3D_SIZE \(dimension)"]
    let step = Float(dimension - 1)
    for blue in 0 ..< dimension {
        for green in 0 ..< dimension {
            for red in 0 ..< dimension {
                let output = transform(Float(red) / step, Float(green) / step, Float(blue) / step)
                lines.append("\(output.0) \(output.1) \(output.2)")
            }
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

struct CubeLUTTests {
    @Test func readsAnIdentityTableInFileOrder() throws {
        let lut = try CubeLUT(cubeFile: Data(cubeFileText(dimension: 3).utf8))
        #expect(lut == CubeLUT.identity(dimension: 3))
        // Red changes fastest: the second color is half red.
        #expect(Array(lut.values[3 ..< 6]) == [0.5, 0, 0])
    }

    @Test func skipsCommentsTitlesBlankLinesAndWindowsLineEnds() throws {
        let header = "\u{FEFF}# Made by a tool\r\nTITLE \"Warm 3 look\"\r\n\r\nDOMAIN_MIN 0.0 0.0 0.0\r\nDOMAIN_MAX 1.0 1.0 1.0\r\nSOME_FUTURE_KEYWORD 12"
        let text = cubeFileText(dimension: 2, header: header).replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "\r\r\n", with: "\r\n")
        let lut = try CubeLUT(cubeFile: Data(text.utf8))
        #expect(lut == CubeLUT.identity(dimension: 2))
    }

    @Test func readsNumbersInEveryUsualNotation() throws {
        let text = "LUT_3D_SIZE 2\n" + Array(repeating: "\t1.000000e-01   .25 1 # trailing words", count: 8).joined(separator: "\n")
        let lut = try CubeLUT(cubeFile: Data(text.utf8))
        #expect(Array(lut.values.prefix(3)) == [0.1, 0.25, 1])
    }

    @Test func refusesWhatItCannotRead() {
        func error(_ text: String) -> CubeLUT.ParseError? {
            do {
                _ = try CubeLUT(cubeFile: Data(text.utf8))
                return nil
            } catch {
                return error as? CubeLUT.ParseError
            }
        }
        #expect(error("LUT_1D_SIZE 4\n0 0 0\n") == .oneDimensional)
        #expect(error("") == .missingSize)
        #expect(error("0 0 0\n") == .missingSize)
        #expect(error("LUT_3D_SIZE 1\n") == .invalidSize(1))
        #expect(error("LUT_3D_SIZE 2\n0 0 0\n") == .wrongCount(expected: 8, found: 1))
        #expect(error(cubeFileText(dimension: 2) + "1 1 1\n") == .wrongCount(expected: 8, found: 9))
        // Two numbers on a line: the third must not be taken from the next line.
        #expect(error("LUT_3D_SIZE 2\n0 0\n0 0 0\n") == .invalidLine(2))
        #expect(error("LUT_3D_SIZE 2\n0 0 nan\n") == .invalidLine(2))
        #expect(error("LUT_3D_SIZE 2\n\u{1}\u{2}binary\n") == .invalidLine(2))
        #expect(CubeLUT.ParseError.oneDimensional.errorDescription?.isEmpty == false)
    }

    @Test func resamplingKeepsTheTransform() throws {
        // A transform a trilinear read reproduces exactly: linear in each channel.
        let text = cubeFileText(dimension: 5) { (1 - $0, $1 * 0.5, $2 * 0.25 + 0.5) }
        let lut = try CubeLUT(cubeFile: Data(text.utf8))
        let smaller = lut.resampled(to: 3)
        #expect(smaller.dimension == 3 && smaller.values.count == 81)
        let expected = try CubeLUT(cubeFile: Data(cubeFileText(dimension: 3) { (1 - $0, $1 * 0.5, $2 * 0.25 + 0.5) }.utf8))
        for (value, reference) in zip(smaller.values, expected.values) {
            #expect(abs(value - reference) < 1e-5)
        }
        #expect(lut.resampled(to: 5) == lut)
    }

    @Test func aTableOverAnotherDomainIsRefittedToTheUnitRange() throws {
        // Identity over 0…2: the unit range only reaches the middle of the table.
        let text = cubeFileText(dimension: 3, header: "DOMAIN_MAX 2 2 2") { ($0 * 2, $1 * 2, $2 * 2) }
        let lut = try CubeLUT(cubeFile: Data(text.utf8))
        for (value, reference) in zip(lut.values, CubeLUT.identity(dimension: 3).values) {
            #expect(abs(value - reference) < 1e-5)
        }
        let resolve = cubeFileText(dimension: 3, header: "LUT_3D_INPUT_RANGE 0 2") { ($0 * 2, $1 * 2, $2 * 2) }
        #expect(try CubeLUT(cubeFile: Data(resolve.utf8)) == lut)
    }

    @Test func coreImageDataIsOpaqueAndWithinRange() {
        let lut = CubeLUT(dimension: 2, values: [Float](repeating: 1.5, count: 12) + [Float](repeating: -0.5, count: 12))
        let floats = lut.rgbaData().withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        #expect(floats.count == 32)
        #expect(Array(floats.prefix(4)) == [1, 1, 1, 1])
        #expect(Array(floats.suffix(4)) == [0, 0, 0, 1])
    }

    /// The largest table commonly shared, as the editor reads it when a look is first tried.
    @Test func readsALargeTableQuickly() throws {
        let data = Data(cubeFileText(dimension: 65) { ($0 * 0.9, $1 * 0.8, $2) }.utf8)
        let start = ContinuousClock.now
        let lut = try CubeLUT(cubeFile: data)
        let parsed = ContinuousClock.now - start
        _ = lut.rgbaData()
        let total = ContinuousClock.now - start
        print("CubeLUT 65: parse \(parsed), with Core Image data \(total), \(data.count / 1024) KB")
        #expect(lut.dimension == 65)
        #expect(total < .milliseconds(500))
    }
}
