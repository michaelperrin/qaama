import CoreGraphics
@testable import EditorKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@MainActor
struct WatermarkStoreTests {
    private func makePNG(in folder: URL, named name: String) throws -> URL {
        let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func importsListsDecodesAndDeletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WatermarkStore(directory: root.appendingPathComponent("store"))
        #expect(store.names.isEmpty)
        let picture = try makePNG(in: root, named: "logo.png")
        let first = try store.importPicture(at: picture)
        let second = try store.importPicture(at: picture)
        #expect(first == "logo.png" && second == "logo 2.png")
        #expect(store.names == ["logo 2.png", "logo.png"])
        #expect(store.image(named: first)?.width == 8)
        #expect(store.image(named: "missing.png") == nil)
        try store.delete(first)
        #expect(store.names == ["logo 2.png"])
    }
}
