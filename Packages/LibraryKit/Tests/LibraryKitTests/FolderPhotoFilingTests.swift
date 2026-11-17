import CoreGraphics
import Foundation
import ImageIO
@testable import LibraryKit
import Testing
import UniformTypeIdentifiers

/// Deleting and duplicating the photos of a folder, and undoing both. The trash is a folder next to
/// the photos, never the user's.
@MainActor
struct FolderPhotoFilingTests {
    @MainActor
    private struct Fixture {
        let base: URL
        let root: URL
        let trash: URL
        let source: FolderLibrarySource
        let store: CatalogStore

        func names(in directory: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        func asset(named name: String) async -> LibraryAsset? {
            for asset in source.assets where await source.resourceInfo(for: asset).originalFileName == name {
                return asset
            }
            return nil
        }
    }

    /// A folder of small images, loaded. `rawTwinOf` names an image that gets a fake RAW next to it:
    /// the pairing looks at types and names, not pixels.
    private func makeFixture(images: [String] = ["a.png", "b.png", "c.png"], rawTwinOf paired: String? = nil) async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FolderPhotoFilingTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in images {
            let context = CGContext(data: nil, width: 12, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 6))
            let type = name.hasSuffix(".jpg") ? UTType.jpeg : UTType.png
            let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        if let paired {
            let raw = root.appendingPathComponent(paired).deletingPathExtension().appendingPathExtension("RAF")
            try Data([0x46, 0x55, 0x4A, 0x49]).write(to: raw)
        }
        let store = try CatalogStore.inMemory()
        let trash = base.appendingPathComponent("Trash")
        let source = FolderLibrarySource(folder: CatalogFolder(bookmark: Data(), displayName: "Source"), url: root, store: store,
                                         previewCache: PreviewCache(directory: base.appendingPathComponent("Previews")), trash: .folder(trash))
        await source.load()
        let fixture = Fixture(base: base, root: root, trash: trash, source: source, store: store)
        await wait { !source.isScanning && source.assets.count == images.count }
        return fixture
    }

    /// Waits for the catalog and the scans to catch up, up to two seconds.
    private func wait(until condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// An undo manager that groups by hand: tests have no run loop to close an event's group.
    private func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    @discardableResult
    private func step<T>(_ manager: UndoManager, _ change: () async throws -> T) async rethrows -> T {
        manager.beginUndoGrouping()
        defer { manager.endUndoGrouping() }
        return try await change()
    }

    @Test func deletingMovesTheFileAndItsSidecarToTheTrashAndUndoingBringsThePhotoBackAsItWas() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source
        let manager = makeUndoManager()
        let photo = try #require(await fixture.asset(named: "b.png"))
        try await source.setRating(4, for: photo)
        #expect(source.deletionNotice(for: [photo]) == "Its file will be moved to the Trash.")

        let deleted = try await step(manager) { try await source.delete([photo], undoManager: manager) }
        #expect(deleted)
        await wait { source.assets.count == 2 }
        #expect(source.asset(id: photo.id) == nil && source.index(of: photo.id) == nil)
        #expect(fixture.names(in: fixture.root) == ["a.png", "c.png"])
        #expect(fixture.names(in: fixture.trash) == ["b.png", "b.png.qaama"])
        #expect(manager.undoActionName == "Delete Photo")

        manager.undo()
        await source.waitUntilFilesAreIdle()
        await wait { source.asset(id: photo.id) != nil }
        #expect(fixture.names(in: fixture.root) == ["a.png", "b.png", "b.png.qaama", "c.png"])
        #expect(source.asset(id: photo.id)?.rating == 4, "the same photo, under the same identifier, with its decisions")
        #expect(source.assets.count == 3)

        // And the deletion can be made again, then undone again.
        #expect(manager.redoActionName == "Delete Photo")
        manager.redo()
        await source.waitUntilFilesAreIdle()
        await wait { source.assets.count == 2 }
        #expect(fixture.names(in: fixture.root) == ["a.png", "c.png"])
        manager.undo()
        await source.waitUntilFilesAreIdle()
        await wait { source.assets.count == 3 }
        #expect(source.asset(id: photo.id)?.rating == 4)
    }

    @Test func severalPhotosAreDeletedAsOneStep() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source
        let manager = makeUndoManager()
        let photos = Array(source.assets.prefix(2))
        #expect(source.deletionNotice(for: photos) == "Their files will be moved to the Trash.")

        try await step(manager) { try await source.delete(photos, undoManager: manager) }
        await wait { source.assets.count == 1 }
        #expect(fixture.names(in: fixture.root).count == 1)
        #expect(manager.undoActionName == "Delete Photos")

        manager.undo()
        await source.waitUntilFilesAreIdle()
        await wait { source.assets.count == 3 }
        #expect(Set(source.assets.map(\.id)).isSuperset(of: photos.map(\.id)))
    }

    @Test func deletingAPhotoThatIsGoneFails() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let stranger = LibraryAsset(id: UUID().uuidString, pixelWidth: 1, pixelHeight: 1, creationDate: nil, isFavorite: false)
        await #expect(throws: LibrarySourceError.self) { try await fixture.source.delete([stranger], undoManager: nil) }

        // The file was removed behind the catalog's back: nothing to move, and the failure is told.
        let photo = try #require(await fixture.asset(named: "a.png"))
        try FileManager.default.removeItem(at: #require(fixture.source.fileURL(for: photo)))
        await #expect(throws: LibrarySourceError.self) { try await fixture.source.delete([photo], undoManager: nil) }
    }

    @Test func aRAWShownForItsPairTakesItsHiddenJPEGAlong() async throws {
        let fixture = try await makeFixture(images: ["DSCF0001.jpg", "other.png"], rawTwinOf: "DSCF0001.jpg")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source
        let manager = makeUndoManager()
        // Two photos listed for three files: the pair shows as its RAW.
        let raw = try #require(source.assets.first { $0.isRAW })
        #expect(raw.pairedAssetID != nil && source.assets.count == 2)

        try await source.duplicate([raw], undoManager: nil)
        await wait { source.assets.count == 3 && !source.isScanning }
        #expect(fixture.names(in: fixture.root) == ["DSCF0001 copy.RAF", "DSCF0001 copy.jpg", "DSCF0001.RAF", "DSCF0001.jpg", "other.png"])
        #expect(source.assets.count(where: { $0.isRAW && $0.pairedAssetID != nil }) == 2, "the copies are a pair too")

        try await step(manager) { try await source.delete([raw], undoManager: manager) }
        await wait { source.asset(id: raw.id) == nil && !source.isScanning }
        #expect(fixture.names(in: fixture.root) == ["DSCF0001 copy.RAF", "DSCF0001 copy.jpg", "other.png"])
        #expect(source.assets.count == 2, "the JPEG didn't stay behind as a photo of its own")

        manager.undo()
        await source.waitUntilFilesAreIdle()
        await wait { source.asset(id: raw.id)?.pairedAssetID != nil }
        #expect(source.asset(id: raw.id)?.pairedAssetID == raw.pairedAssetID)
    }

    @Test func whenTheTwinsAreShownEachPhotoIsDeletedOnItsOwn() async throws {
        let fixture = try await makeFixture(images: ["DSCF0001.jpg"], rawTwinOf: "DSCF0001.jpg")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source
        source.query.includesPairedJPEGs = true
        await wait { source.assets.count == 2 }
        let raw = try #require(source.assets.first { $0.isRAW })

        try await source.delete([raw], undoManager: nil)
        await wait { source.assets.count == 1 && !source.isScanning }
        #expect(fixture.names(in: fixture.root) == ["DSCF0001.jpg"])
    }

    @Test func aCopyIsANewPhotoWithTheSameDecisionsAndUndoingTrashesIt() async throws {
        let fixture = try await makeFixture(images: ["a.png", "b.png"])
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source
        let manager = makeUndoManager()
        let photo = try #require(await fixture.asset(named: "a.png"))
        try await source.setRating(5, for: photo)
        try await source.setKeywords(["lapland"], for: photo)

        try await step(manager) { try await source.duplicate([photo], undoManager: manager) }
        await wait { source.assets.count == 3 && !source.isScanning }
        #expect(fixture.names(in: fixture.root) == ["a copy.png", "a copy.png.qaama", "a.png", "a.png.qaama", "b.png"])
        let copy = try #require(await fixture.asset(named: "a copy.png"))
        #expect(copy.id != photo.id)
        #expect(copy.rating == 5 && copy.keywords == ["lapland"])
        #expect(source.asset(id: photo.id)?.rating == 5, "the original is still itself")
        #expect(manager.undoActionName == "Duplicate")

        manager.undo()
        await source.waitUntilFilesAreIdle()
        await wait { source.assets.count == 2 }
        #expect(fixture.names(in: fixture.root) == ["a.png", "a.png.qaama", "b.png"])
        #expect(fixture.names(in: fixture.trash) == ["a copy.png", "a copy.png.qaama"])

        // Redoing takes the very copy back out of the trash: the same photo again.
        manager.redo()
        await source.waitUntilFilesAreIdle()
        await wait { source.asset(id: copy.id) != nil }
        #expect(source.asset(id: copy.id)?.rating == 5)
    }

    @Test func aSourceThatDoesNotScanStillSeesItsDeletionAtOnce() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        // The second view of the folder that the map of every library uses: it only follows the catalog.
        let view = FolderLibrarySource(folder: CatalogFolder(id: fixture.source.id, bookmark: Data(), displayName: "Source"), url: fixture.root,
                                       store: fixture.store, scans: false, trash: .folder(fixture.trash))
        await view.load()
        await wait { view.assets.count == 3 }
        let photo = try #require(view.assets.first)

        try await view.delete([photo], undoManager: nil)
        await wait { view.assets.count == 2 }
        #expect(view.asset(id: photo.id) == nil)
        await wait { fixture.source.assets.count == 2 }
        #expect(fixture.source.asset(id: photo.id) == nil)
    }
}
