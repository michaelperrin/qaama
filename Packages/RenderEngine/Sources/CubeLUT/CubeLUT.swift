import Foundation

/// A 3D color lookup table read from a `.cube` file, the text format of DaVinci Resolve and Adobe
/// that nearly every LUT is shared in: a header (`LUT_3D_SIZE`, optionally a title and an input
/// domain), then one output color per line for each point of a grid over the input colors.
///
/// Reading one is a loop over hundreds of thousands of numbers, and fitting one to another grid a
/// loop over as many points: this target is always compiled optimized, like `HealingFill`.
public struct CubeLUT: Equatable, Sendable {
    /// Points per axis.
    public let dimension: Int
    /// `dimension³` RGB triplets for inputs spread over 0…1, red changing fastest, then green, then
    /// blue: the order of the file, and the one Core Image expects.
    public let values: [Float]

    /// What a file may declare. The format allows up to 256; tables in the wild have 17 to 65.
    public static let dimensionRange = 2 ... 256

    public enum ParseError: Error, Equatable, LocalizedError {
        /// A table of three separate curves, which this type doesn't hold.
        case oneDimensional
        /// Colors came before any `LUT_3D_SIZE`, or the file has none.
        case missingSize
        case invalidSize(Int)
        /// A line that is neither a comment, a keyword nor three numbers. Lines count from 1.
        case invalidLine(Int)
        case wrongCount(expected: Int, found: Int)

        public var errorDescription: String? {
            switch self {
            case .oneDimensional: "it is a 1D LUT; only 3D LUTs are supported."
            case .missingSize: "it doesn't say its size (LUT_3D_SIZE)."
            case let .invalidSize(size): "its size (\(size)) is outside \(CubeLUT.dimensionRange.lowerBound) to \(CubeLUT.dimensionRange.upperBound)."
            case let .invalidLine(line): "line \(line) can't be read."
            case let .wrongCount(expected, found): "it holds \(found) colors where its size calls for \(expected)."
            }
        }
    }

    public init(dimension: Int, values: [Float]) {
        precondition(values.count == dimension * dimension * dimension * 3, "a cube holds dimension³ RGB triplets")
        self.dimension = dimension
        self.values = values
    }

    /// The table that changes nothing, for tests and as a reference.
    public static func identity(dimension: Int) -> CubeLUT {
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 3)
        let step = Float(dimension - 1)
        for blue in 0 ..< dimension {
            for green in 0 ..< dimension {
                for red in 0 ..< dimension {
                    values.append(Float(red) / step)
                    values.append(Float(green) / step)
                    values.append(Float(blue) / step)
                }
            }
        }
        return CubeLUT(dimension: dimension, values: values)
    }

    // MARK: - Reading

    /// Reads the contents of a `.cube` file. A table whose input domain isn't 0…1 is refitted to
    /// 0…1, so every `CubeLUT` covers the same inputs.
    public init(cubeFile data: Data) throws {
        var parser = Parser()
        try data.withUnsafeBytes { try parser.read($0.bindMemory(to: UInt8.self)) }
        guard let dimension = parser.dimension else { throw ParseError.missingSize }
        let expected = dimension * dimension * dimension
        guard parser.found == expected else { throw ParseError.wrongCount(expected: expected, found: parser.found) }
        if parser.hasUnitDomain {
            self.init(dimension: dimension, values: parser.values)
        } else {
            self.init(dimension: dimension, values: Self.resample(parser.values, dimension: dimension, to: dimension,
                                                                  domainMin: parser.domainMin, domainMax: parser.domainMax))
        }
    }

    /// Reads the file byte by byte: no string per line, and numbers in the format's own notation
    /// (a point for the decimals) whatever the user's locale.
    private struct Parser {
        var dimension: Int?
        var values: [Float] = []
        /// Colors read, including those past what the size calls for (they aren't stored).
        var found = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]

        var hasUnitDomain: Bool {
            domainMin == [0, 0, 0] && domainMax == [1, 1, 1]
        }

        private typealias Bytes = UnsafeBufferPointer<UInt8>

        private static func isBlank(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        }

        mutating func read(_ bytes: UnsafeBufferPointer<UInt8>) throws {
            let count = bytes.count
            var position = 0
            // A byte order mark, as some Windows tools write.
            if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                position = 3
            }
            var lineNumber = 0
            while position < count {
                var lineEnd = position
                while lineEnd < count, bytes[lineEnd] != UInt8(ascii: "\n"), bytes[lineEnd] != UInt8(ascii: "\r") {
                    lineEnd += 1
                }
                lineNumber += 1
                try readLine(bytes, from: position, to: lineEnd, number: lineNumber)
                // "\r\n" ends one line, not two.
                let isWindowsEnd = lineEnd + 1 < count && bytes[lineEnd] == UInt8(ascii: "\r") && bytes[lineEnd + 1] == UInt8(ascii: "\n")
                position = lineEnd + (isWindowsEnd ? 2 : 1)
            }
        }

        private mutating func readLine(_ bytes: Bytes, from start: Int, to end: Int, number: Int) throws {
            var position = start
            while position < end, Self.isBlank(bytes[position]) {
                position += 1
            }
            guard position < end, bytes[position] != UInt8(ascii: "#") else { return }
            let first = bytes[position]
            if (first >= UInt8(ascii: "A") && first <= UInt8(ascii: "Z")) || (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z")) {
                try readKeyword(bytes, from: position, to: end, number: number)
                return
            }
            guard let dimension else { throw ParseError.missingSize }
            guard let red = Self.number(bytes, &position, lineEnd: end), let green = Self.number(bytes, &position, lineEnd: end),
                  let blue = Self.number(bytes, &position, lineEnd: end) else { throw ParseError.invalidLine(number) }
            if found < dimension * dimension * dimension {
                values.append(red)
                values.append(green)
                values.append(blue)
            }
            found += 1
        }

        /// Header lines. Titles and the keywords of other tools are skipped.
        private mutating func readKeyword(_ bytes: Bytes, from start: Int, to end: Int, number: Int) throws {
            var position = start
            while position < end, !Self.isBlank(bytes[position]) {
                position += 1
            }
            let keyword = String(decoding: Bytes(rebasing: bytes[start ..< position]), as: UTF8.self)
            func numbers(_ count: Int) throws -> [Float] {
                try (0 ..< count).map { _ in
                    guard let value = Self.number(bytes, &position, lineEnd: end) else { throw ParseError.invalidLine(number) }
                    return value
                }
            }
            switch keyword {
            case "LUT_1D_SIZE":
                throw ParseError.oneDimensional
            case "LUT_3D_SIZE":
                let size = try Int(numbers(1)[0])
                guard CubeLUT.dimensionRange.contains(size) else { throw ParseError.invalidSize(size) }
                dimension = size
                values.reserveCapacity(size * size * size * 3)
            case "DOMAIN_MIN":
                domainMin = try numbers(3)
            case "DOMAIN_MAX":
                domainMax = try numbers(3)
            case "LUT_3D_INPUT_RANGE":
                // Resolve's way of giving the same domain to the three channels.
                let range = try numbers(2)
                domainMin = [range[0], range[0], range[0]]
                domainMax = [range[1], range[1], range[1]]
            default:
                break
            }
        }

        /// Reads one decimal number (`0.25`, `-1`, `1.5e-3`) at `position` and moves past it; nil
        /// when the line holds none there, or something else than a number.
        private static func number(_ bytes: Bytes, _ position: inout Int, lineEnd: Int) -> Float? {
            var index = position
            while index < lineEnd, isBlank(bytes[index]) {
                index += 1
            }
            func digit(at index: Int) -> Int? {
                guard index < lineEnd, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") else { return nil }
                return Int(bytes[index] - UInt8(ascii: "0"))
            }
            func sign(at index: inout Int) -> Bool {
                guard index < lineEnd, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") else { return false }
                index += 1
                return bytes[index - 1] == UInt8(ascii: "-")
            }
            let isNegative = sign(at: &index)
            var mantissa = 0.0
            var digits = 0
            // The power of ten the mantissa is to be multiplied by.
            var exponent = 0
            while let value = digit(at: index) {
                mantissa = mantissa * 10 + Double(value)
                digits += 1
                index += 1
            }
            if index < lineEnd, bytes[index] == UInt8(ascii: ".") {
                index += 1
                while let value = digit(at: index) {
                    mantissa = mantissa * 10 + Double(value)
                    digits += 1
                    exponent -= 1
                    index += 1
                }
            }
            guard digits > 0 else { return nil }
            if index < lineEnd, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                let isSmall = sign(at: &index)
                var written = 0
                var writtenDigits = 0
                while let value = digit(at: index) {
                    written = min(written * 10 + value, 10000)
                    writtenDigits += 1
                    index += 1
                }
                guard writtenDigits > 0 else { return nil }
                exponent += isSmall ? -written : written
            }
            // A number ends at white space or with the line: "0.5abc" is not one.
            guard index == lineEnd || isBlank(bytes[index]) else { return nil }
            // Dividing by a power of ten is exact where multiplying by its inverse is not.
            let magnitude = exponent < 0 ? mantissa / pow(10, Double(-exponent)) : mantissa * pow(10, Double(exponent))
            let value = Float(isNegative ? -magnitude : magnitude)
            guard value.isFinite else { return nil }
            position = index
            return value
        }
    }

    // MARK: - Fitting

    /// The same table on a grid of another size, each point read between its eight neighbors.
    public func resampled(to newDimension: Int) -> CubeLUT {
        guard newDimension != dimension else { return self }
        return CubeLUT(dimension: newDimension, values: Self.resample(values, dimension: dimension, to: newDimension,
                                                                      domainMin: [0, 0, 0], domainMax: [1, 1, 1]))
    }

    /// Reads a table given over `domainMin…domainMax` at the points of a grid of `target` points
    /// over 0…1. Inputs outside the table's domain take the color of its nearest edge.
    private static func resample(_ source: [Float], dimension: Int, to target: Int, domainMin: [Float], domainMax: [Float]) -> [Float] {
        /// Where each point of the new grid falls in the old one, per channel: the lower neighbor
        /// and how far toward the next.
        func positions(_ channel: Int) -> [(index: Int, fraction: Float)] {
            let span = domainMax[channel] - domainMin[channel]
            return (0 ..< target).map { point in
                let input = Float(point) / Float(target - 1)
                let unit = span > 0 ? min(max((input - domainMin[channel]) / span, 0), 1) : 0
                let position = unit * Float(dimension - 1)
                let index = min(Int(position), dimension - 2)
                return (index, position - Float(index))
            }
        }
        let reds = positions(0), greens = positions(1), blues = positions(2)
        var output = [Float](repeating: 0, count: target * target * target * 3)
        source.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { output in
                var offset = 0
                for blue in blues {
                    for green in greens {
                        // The four rows of the old grid around this point.
                        let row00 = (blue.index * dimension + green.index) * dimension
                        let row01 = row00 + dimension
                        let row10 = row00 + dimension * dimension
                        let row11 = row10 + dimension
                        for red in reds {
                            for channel in 0 ..< 3 {
                                func along(_ row: Int) -> Float {
                                    let near = source[(row + red.index) * 3 + channel]
                                    let far = source[(row + red.index + 1) * 3 + channel]
                                    return near + (far - near) * red.fraction
                                }
                                let front = along(row00) + (along(row01) - along(row00)) * green.fraction
                                let back = along(row10) + (along(row11) - along(row10)) * green.fraction
                                output[offset + channel] = front + (back - front) * blue.fraction
                            }
                            offset += 3
                        }
                    }
                }
            }
        }
        return output
    }

    // MARK: - Core Image

    /// The table as Core Image's color cube filters take it: opaque RGBA in 32-bit floats, colors
    /// kept within 0…1.
    public func rgbaData() -> Data {
        let count = dimension * dimension * dimension
        var floats = [Float32](repeating: 1, count: count * 4)
        values.withUnsafeBufferPointer { values in
            floats.withUnsafeMutableBufferPointer { floats in
                for index in 0 ..< count {
                    for channel in 0 ..< 3 {
                        floats[index * 4 + channel] = min(max(values[index * 3 + channel], 0), 1)
                    }
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
