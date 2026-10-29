import CoreGraphics
import Foundation
import ImageIO
@testable import LibraryKit
import Testing
import UniformTypeIdentifiers

struct FolderScannerTests {
    /// Builds a folder with two images (one nested), a text file and a hidden image.
    private func makeFixtureFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderScannerTests-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeImage(width: 30, height: 20, type: .png, to: root.appendingPathComponent("wide.png"))
        try writeImage(width: 10, height: 40, type: .jpeg, to: nested.appendingPathComponent("tall.jpg"))
        try writeImage(width: 5, height: 5, type: .png, to: root.appendingPathComponent(".hidden.png"))
        try "not an image".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        return root
    }

    private func writeImage(width: Int, height: Int, type: UTType, to url: URL) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func listsImagesRecursivelyAndSkipsOtherFiles() throws {
        let root = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let assets = try FolderScanner.scan(root)

        #expect(assets.count == 2)
        let names = Set(assets.map { URL(filePath: $0.id).lastPathComponent })
        #expect(names == ["wide.png", "tall.jpg"])
    }

    @Test func readsDimensionsFromTheHeader() throws {
        let root = try makeFixtureFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let assets = try FolderScanner.scan(root)
        let wide = try #require(assets.first { $0.id.hasSuffix("wide.png") })
        let tall = try #require(assets.first { $0.id.hasSuffix("tall.jpg") })

        #expect(wide.pixelWidth == 30 && wide.pixelHeight == 20)
        #expect(tall.pixelWidth == 10 && tall.pixelHeight == 40)
        #expect(wide.creationDate != nil)
        #expect(wide.rating == 0 && !wide.isFavorite)
    }

    @Test func failsOnMissingFolder() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        #expect(throws: LibrarySourceError.self) {
            try FolderScanner.scan(missing)
        }
    }
}
