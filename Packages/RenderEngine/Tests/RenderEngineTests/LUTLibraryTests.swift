import CoreImage
import EditModel
import Foundation
@testable import RenderEngine
import Testing

/// A temporary folder holding `.cube` files to import and the library they go to; removed with
/// `remove()`.
struct LUTFixture {
    let root: URL
    let library: LUTLibrary

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = LUTLibrary(directory: root.appendingPathComponent("library"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes the smallest table (two points per axis) for a transform of the cube's corners.
    func writeCube(named name: String, transform: (Double, Double, Double) -> (Double, Double, Double) = { ($0, $1, $2) }) throws -> URL {
        var lines = ["TITLE \"\(name)\"", "LUT_3D_SIZE 2"]
        for blue in [0.0, 1.0] {
            for green in [0.0, 1.0] {
                for red in [0.0, 1.0] {
                    let output = transform(red, green, blue)
                    lines.append("\(output.0) \(output.1) \(output.2)")
                }
            }
        }
        let url = root.appendingPathComponent(name)
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }
}

struct LUTLibraryTests {
    @Test func importsListsReadsAndDeletes() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        let library = fixture.library
        #expect(library.names().isEmpty)
        #expect(library.table(named: "Film") == nil)

        let file = try fixture.writeCube(named: "Film.cube")
        #expect(try library.importFile(at: file) == "Film")
        #expect(try library.importFile(at: fixture.writeCube(named: "film 10.CUBE")) == "film 10")
        #expect(try library.importFile(at: fixture.writeCube(named: "Film 2.cube")) == "Film 2")
        #expect(library.names() == ["Film", "Film 2", "film 10"])

        let table = try #require(library.table(named: "Film"))
        #expect(table.dimension == 2 && table.data.count == 8 * 4 * MemoryLayout<Float32>.size)

        try library.delete("Film")
        #expect(library.names() == ["Film 2", "film 10"])
        #expect(library.table(named: "Film") == nil, "a deleted table is no longer served from memory")
    }

    @Test func theSameFileTwiceIsOneTableAndAnotherOfThatNameGetsACounter() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        let file = try fixture.writeCube(named: "Film.cube")
        #expect(try fixture.library.importFile(at: file) == "Film")
        #expect(try fixture.library.importFile(at: file) == "Film")
        let other = try fixture.writeCube(named: "Film.cube") { (1 - $0, $1, $2) }
        #expect(try fixture.library.importFile(at: other) == "Film 2")
        #expect(try fixture.library.importFile(at: other) == "Film 2")
        #expect(fixture.library.names() == ["Film", "Film 2"])
    }

    @Test func refusesFilesThatAreNotTables() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("Curves.cube")
        try Data("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".utf8).write(to: file)
        #expect {
            try fixture.library.importFile(at: file)
        } throws: { error in
            error.localizedDescription == "“Curves.cube” can't be used as a LUT: it is a 1D LUT; only 3D LUTs are supported."
        }
        #expect(fixture.library.names().isEmpty)
    }

    @Test func aBrokenFileOrANameOutOfTheFolderGivesNoTable() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Film.cube"))
        // Dropped in the folder by hand, without the check an import makes.
        try Data("not a table".utf8).write(to: fixture.library.directory.appendingPathComponent("Broken.cube"))
        #expect(fixture.library.table(named: "Broken") == nil)
        #expect(fixture.library.table(named: "Broken") == nil)
        try Data("LUT_3D_SIZE 2\n".utf8).write(to: fixture.root.appendingPathComponent("Outside.cube"))
        #expect(fixture.library.table(named: "../Outside") == nil)
        #expect(fixture.library.table(named: "") == nil)
    }

    @Test func tablesLargerThanTheLimitAreRefitted() throws {
        let dimension = LUTLibrary.maximumDimension + 2
        var lines = ["LUT_3D_SIZE \(dimension)"]
        let step = Double(dimension - 1)
        for blue in 0 ..< dimension {
            for green in 0 ..< dimension {
                for red in 0 ..< dimension {
                    lines.append("\(Double(red) / step) \(Double(green) / step) \(Double(blue) / step)")
                }
            }
        }
        let table = try LUTLibrary.table(from: Data(lines.joined(separator: "\n").utf8))
        #expect(table.dimension == LUTLibrary.maximumDimension)
    }
}

/// The LUT as the pipeline applies it.
struct LUTRenderingTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let color = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

    private func rendered(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private func recipe(_ lut: LUT) -> EditRecipe {
        EditRecipe(adjustments: AdjustmentSet(lut: lut))
    }

    @Test func aTableRemapsDisplayColors() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        // Negative: exact between the corners of the cube, in sRGB values.
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Negative.cube") { (1 - $0, 1 - $1, 1 - $2) })
        let output = rendered(RenderPipeline.apply(recipe(LUT(name: "Negative")), to: color, geometry: nil, luts: fixture.library))
        #expect(abs(output.r - 0.2) < 0.02 && abs(output.g - 0.6) < 0.02 && abs(output.b - 0.8) < 0.02)
    }

    @Test func intensityMixesTheTableWithThePhoto() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Black.cube") { _, _, _ in (0, 0, 0) })
        let original = rendered(color)
        let full = rendered(RenderPipeline.apply(recipe(LUT(name: "Black")), to: color, geometry: nil, luts: fixture.library))
        let half = rendered(RenderPipeline.apply(recipe(LUT(name: "Black", intensity: 0.5)), to: color, geometry: nil, luts: fixture.library))
        #expect(full.r < 0.01)
        #expect(half.r > 0.2 && half.r < original.r - 0.1, "halfway between the photo and the table")
    }

    @Test func switchedOffMissingOrWithoutATableLeavesThePhotoUntouched() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Negative.cube") { (1 - $0, 1 - $1, 1 - $2) })
        for lut in [LUT(isEnabled: false, name: "Negative"), LUT(name: "Negative", intensity: 0), LUT(name: nil)] {
            #expect(RenderPipeline.apply(recipe(lut), to: color, geometry: nil, luts: fixture.library) === color)
        }
        let original = rendered(color)
        let missing = rendered(RenderPipeline.apply(recipe(LUT(name: "Gone")), to: color, geometry: nil, luts: fixture.library))
        #expect(missing == original)
    }

    @Test func theTableComesAfterBlackAndWhiteSoItCanToneIt() throws {
        let fixture = try LUTFixture()
        defer { fixture.remove() }
        // Sepia-like: keeps red, halves blue.
        _ = try fixture.library.importFile(at: fixture.writeCube(named: "Tone.cube") { ($0, $1, $2 * 0.5) })
        let adjustments = AdjustmentSet(monochrome: Monochrome(), lut: LUT(name: "Tone"))
        let output = rendered(RenderPipeline.apply(EditRecipe(adjustments: adjustments), to: color, geometry: nil, luts: fixture.library))
        #expect(abs(output.r - output.g) < 0.02, "black and white first")
        #expect(output.b < output.r - 0.1, "then the table's tone")
    }

    @Test func theColorMixerUpstreamLeavesTheTableOut() {
        var recipe = EditRecipe(adjustments: AdjustmentSet(exposure: 1, lut: LUT(name: "Film")))
        recipe.global.hsl = nil
        #expect(RenderPipeline.colorMixerUpstream(of: recipe, layerIndex: 0).global.lut == nil)
    }
}

private func == (lhs: (r: Double, g: Double, b: Double), rhs: (r: Double, g: Double, b: Double)) -> Bool {
    lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b
}
