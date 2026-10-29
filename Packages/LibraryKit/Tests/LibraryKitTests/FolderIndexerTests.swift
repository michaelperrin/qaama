import CoreGraphics
import Foundation
import ImageIO
@testable import LibraryKit
import Testing
import UniformTypeIdentifiers

/// Scenarios of docs/catalogue.md §8: the same file keeps the same identifier through renames, moves,
/// disappearances and sidecar edits.
struct FolderIndexerTests {
    private struct Fixture {
        let store: CatalogStore
        let indexer: FolderIndexer
        let folder: CatalogFolder
        let root: URL

        func index() async throws -> IndexResult {
            try await indexer.index(folder: folder, at: root)
        }

        func items() async throws -> [CatalogItem] {
            try await store.items(inFolder: folder.id)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderIndexerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Trip"), withIntermediateDirectories: true)
        try writeImage(to: root.appendingPathComponent("a.png"), seed: 1)
        try writeImage(to: root.appendingPathComponent("Trip/b.jpg"), seed: 2, type: .jpeg)
        try "notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Fixture")
        return Fixture(store: store, indexer: FolderIndexer(store: store), folder: folder, root: root)
    }

    private func writeImage(to url: URL, seed: Int, type: UTType = .png) throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(seed) / 10, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func indexesImagesOnlyAndMatchesOnRescan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try await fixture.index()
        #expect(first == IndexResult(listed: 2, created: 2, matched: 0, missing: 0))
        let items = try await fixture.items()
        #expect(Set(items.map(\.relativePath)) == ["a.png", "Trip/b.jpg"])
        #expect(items.allSatisfy { $0.fileIdentifier != nil && $0.needsMetadata })

        let second = try await fixture.index()
        #expect(second == IndexResult(listed: 2, created: 0, matched: 2, missing: 0))
        #expect(try await Set(fixture.items().map(\.id)) == Set(items.map(\.id)))
    }

    @Test func keepsIdentityThroughRenameAndMove() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.index()
        let original = try #require(try await fixture.items().first { $0.relativePath == "a.png" })

        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("a.png"),
                                         to: fixture.root.appendingPathComponent("Trip/renamed.png"))
        let result = try await fixture.index()
        #expect(result.created == 0 && result.matched == 2)
        let moved = try #require(try await fixture.store.item(id: original.id))
        #expect(moved.relativePath == "Trip/renamed.png" && moved.fileName == "renamed.png")
    }

    @Test func marksMissingThenRestores() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.index()
        let original = try #require(try await fixture.items().first { $0.relativePath == "a.png" })
        let aside = fixture.root.deletingLastPathComponent().appendingPathComponent("aside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: aside) }

        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("a.png"), to: aside)
        #expect(try await fixture.index().missing == 1)
        #expect(try await fixture.items().count == 1)

        try FileManager.default.moveItem(at: aside, to: fixture.root.appendingPathComponent("a.png"))
        let back = try await fixture.index()
        #expect(back.created == 0 && back.matched == 2)
        #expect(try await fixture.store.item(id: original.id)?.isMissing == false)
    }

    @Test func importsSidecarDecisionsAndIdentifier() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let image = fixture.root.appendingPathComponent("a.png")
        let sidecar = Sidecar(rating: 5, flag: .picked, keywords: ["test"], recipeData: Data(#"{"exposure":1}"#.utf8))
        try sidecar.write(forImageAt: image)

        _ = try await fixture.index()
        let item = try #require(try await fixture.store.item(id: sidecar.id))
        #expect(item.rating == 5 && item.flag == .picked && item.keywords == ["test"] && item.hasEdit)
        #expect(item.sidecarModified != nil)

        // The sidecar changes on disk: decisions follow on the next scan.
        var edited = sidecar
        edited.rating = 1
        try edited.write(forImageAt: image)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: Sidecar.url(for: image).path)
        _ = try await fixture.index()
        #expect(try await fixture.store.item(id: sidecar.id)?.rating == 1)

        // The sidecar disappears: nothing remains of the decisions, the item itself stays.
        try FileManager.default.removeItem(at: Sidecar.url(for: image))
        _ = try await fixture.index()
        let cleared = try #require(try await fixture.store.item(id: sidecar.id))
        #expect(cleared.rating == 0 && !cleared.hasEdit && cleared.sidecarModified == nil)
    }

    @Test func recognizesCopiesByFingerprintAndDuplicateSidecars() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.index()
        var original = try #require(try await fixture.items().first { $0.relativePath == "a.png" })
        let image = fixture.root.appendingPathComponent("a.png")
        original.fingerprint = try Fingerprint.compute(for: image, fileSize: original.fileSize, contentModified: original.contentModified)
        try await fixture.store.save(original)

        // Copy, then remove the original: a new file identifier, but the same bytes and dates.
        let copy = fixture.root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: image, to: copy)
        try FileManager.default.setAttributes([.modificationDate: original.contentModified], ofItemAtPath: copy.path)
        try FileManager.default.removeItem(at: image)
        let result = try await fixture.index()
        #expect(result.created == 0 && result.missing == 0)
        #expect(try await fixture.store.item(id: original.id)?.relativePath == "copy.png")

        // Two files carrying the same sidecar identifier: the second one gets its own.
        let sidecar = Sidecar(rating: 3)
        try sidecar.write(forImageAt: copy)
        try sidecar.write(forImageAt: fixture.root.appendingPathComponent("Trip/b.jpg"))
        _ = try await fixture.index()
        let ids = try await Set(fixture.items().map(\.id))
        #expect(ids.count == 2)
    }
}
