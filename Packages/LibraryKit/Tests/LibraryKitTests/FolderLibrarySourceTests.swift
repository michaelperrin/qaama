import CoreGraphics
import Foundation
import ImageIO
@testable import LibraryKit
import Testing
import UniformTypeIdentifiers

@MainActor
struct FolderLibrarySourceTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderLibrarySourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a.png", "b.png"] {
            let context = CGContext(data: nil, width: 12, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 6))
            let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        return root
    }

    private func makeSource(root: URL) throws -> FolderLibrarySource {
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Source")
        let cache = PreviewCache(directory: root.appendingPathComponent(".previews"))
        return FolderLibrarySource(folder: folder, url: root, store: store, previewCache: cache)
    }

    /// Waits for the observation to deliver, up to a second.
    private func wait(until condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func loadsAssetsWithStableIdentifiersAndReadsMetadata() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root)

        await source.load()
        await wait { source.assets.count == 2 && !source.isScanning }
        #expect(source.assets.count == 2)
        #expect(source.assets.allSatisfy { UUID(uuidString: $0.id) != nil })
        await wait { source.assets.allSatisfy { $0.pixelWidth == 12 } }
        #expect(source.assets.allSatisfy { $0.pixelWidth == 12 && $0.pixelHeight == 6 })
        #expect(source.lastLoadDuration != nil && source.loadError == nil)
    }

    @Test func ratingWritesTheSidecarAndTheCatalog() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root)
        await source.load()
        await wait { source.assets.count == 2 && !source.isScanning }
        let asset = try #require(source.assets.first)

        try await source.setRating(4, for: asset)
        await wait { source.assets.first { $0.id == asset.id }?.rating == 4 }
        #expect(source.assets.first { $0.id == asset.id }?.rating == 4)

        let image = root.appendingPathComponent(asset.id == source.assets[0].id ? "a.png" : "b.png")
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".qaama") }
        #expect(sidecars.count == 1)
        let sidecar = try #require(try Sidecar.read(forImageAt: root.appendingPathComponent(String(sidecars[0].dropLast(6)))))
        #expect(sidecar.rating == 4 && sidecar.id.uuidString == asset.id)
        _ = image

        // Back to zero: the sidecar disappears, the catalog follows.
        try await source.setRating(0, for: asset)
        await wait { source.assets.first { $0.id == asset.id }?.rating == 0 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".qaama") }.isEmpty)
    }

    @Test func savingAnEditMarksTheAssetAndKeepsTheRating() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root)
        await source.load()
        await wait { source.assets.count == 2 && !source.isScanning }
        let asset = try #require(source.assets.first)
        try await source.setRating(3, for: asset)

        let jpeg = try #require(CGImageSourceCreateWithURL(root.appendingPathComponent("a.png") as CFURL, nil)).makeJPEG()
        try await source.saveEdit(EditingOutput(recipeData: Data(#"{"exposure":1}"#.utf8), renderedJPEG: jpeg), for: asset)
        await wait { source.assets.first { $0.id == asset.id }?.hasEdit == true }
        let edited = try #require(source.assets.first { $0.id == asset.id })
        #expect(edited.hasEdit && edited.rating == 3)
        #expect(try await source.editingInput(for: edited).recipeData != nil)

        try await source.saveEdit(EditingOutput(recipeData: Data(), renderedJPEG: Data(), isReset: true), for: edited)
        await wait { source.assets.first { $0.id == asset.id }?.hasEdit == false }
        let reset = try #require(source.assets.first { $0.id == asset.id })
        #expect(!reset.hasEdit && reset.rating == 3)
    }
}

private extension CGImageSource {
    func makeJPEG() -> Data {
        let image = CGImageSourceCreateImageAtIndex(self, 0, nil)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
