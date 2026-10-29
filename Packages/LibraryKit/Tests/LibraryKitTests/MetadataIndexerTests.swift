import CoreGraphics
import Foundation
import ImageIO
@testable import LibraryKit
import Testing
import UniformTypeIdentifiers

struct MetadataIndexerTests {
    private func makeFolder(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataIndexerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0 ..< fileCount {
            let context = CGContext(data: nil, width: 10 + index, height: 5, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.fill(CGRect(x: 0, y: 0, width: 10 + index, height: 5))
            let url = root.appendingPathComponent(String(format: "img-%02d.png", index))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            let exif = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:0\(1 + index % 9) 10:00:00"]]
            CGImageDestinationAddImage(destination, context.makeImage()!, exif as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
        }
        return root
    }

    @Test func readsHeadersInBatchesAndStoresThem() async throws {
        let root = try makeFolder(fileCount: 7)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Batches")
        _ = try await FolderIndexer(store: store).index(folder: folder, at: root)

        let read = try await MetadataIndexer(store: store, batchSize: 3).run(folder: folder, at: root)
        #expect(read == 7)

        let items = try await store.items(inFolder: folder.id)
        #expect(items.allSatisfy { !$0.needsMetadata && $0.fingerprint != nil && $0.captureDate != nil })
        #expect(items.first { $0.fileName == "img-03.png" }?.pixelWidth == 13)
        #expect(try await store.itemsNeedingMetadata(inFolder: folder.id, limit: 10).isEmpty)
        // Nothing left to do: a second run is a no-op.
        #expect(try await MetadataIndexer(store: store).run(folder: folder, at: root) == 0)
    }

    @Test func preferredItemsComeFirst() async throws {
        let root = try makeFolder(fileCount: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Preferred")
        _ = try await FolderIndexer(store: store).index(folder: folder, at: root)
        let last = try #require(try await store.items(inFolder: folder.id).first { $0.fileName == "img-04.png" })

        let batch = try await store.itemsNeedingMetadata(inFolder: folder.id, limit: 2, preferring: [last.id])
        #expect(batch.map(\.fileName) == ["img-04.png", "img-00.png"])
    }

    @Test func unreadableFilesAreMarkedReadWithoutMetadata() async throws {
        let root = try makeFolder(fileCount: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Broken")
        _ = try await FolderIndexer(store: store).index(folder: folder, at: root)
        try Data("garbage".utf8).write(to: root.appendingPathComponent("img-00.png"))

        _ = try await MetadataIndexer(store: store).run(folder: folder, at: root)
        let item = try #require(try await store.items(inFolder: folder.id).first)
        #expect(!item.needsMetadata && item.pixelWidth == nil)
    }
}
