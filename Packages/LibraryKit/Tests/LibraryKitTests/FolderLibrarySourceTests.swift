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
        var names: [String?] = []
        for asset in source.assets {
            await names.append(source.resourceInfo(for: asset).originalFileName)
        }
        #expect(names.allSatisfy { $0?.hasSuffix(".jpg") == true || $0?.hasSuffix(".png") == true || $0?.hasSuffix(".JPG") == true })
    }

    @Test func detailsNameTheFileAndGiveItsHeaderWhetherIndexedOrNot() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root)
        await source.load()
        await wait { source.assets.count == 2 }

        // Asked as soon as the files are listed: the metadata phase may not have read them yet.
        for asset in source.assets {
            let early = await source.details(for: asset, allowingDownload: false)
            #expect(early.fileName == "a.png" || early.fileName == "b.png")
            #expect(early.metadata?.pixelWidth == 12 && early.metadata?.pixelHeight == 6)
            #expect(!early.isOriginalInCloud)
        }

        await wait { source.assets.allSatisfy { $0.pixelWidth == 12 } && !source.isScanning }
        let names = await Set(source.assets.asyncMap { await source.details(for: $0, allowingDownload: false).fileName })
        #expect(names == ["a.png", "b.png"])
        let indexed = try await source.details(for: #require(source.assets.first), allowingDownload: false)
        #expect(indexed.metadata?.pixelWidth == 12 && indexed.metadata?.pixelHeight == 6)
    }

    @Test func detailsCarryTheLocationWrittenInTheFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderLibrarySourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 12, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 6))
        let gps: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E",
        ]]
        let destination = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent("tower.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), gps as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let source = try makeSource(root: root)
        await source.load()
        await wait { source.assets.count == 1 && source.assets.allSatisfy { $0.pixelWidth == 12 } && !source.isScanning }
        // Indexed by now: the location still comes, from the file, since the catalog doesn't keep it.
        let details = try await source.details(for: #require(source.assets.first), allowingDownload: false)
        let location = try #require(details.metadata?.location)
        #expect(abs(location.latitude - 48.8584) < 0.0001 && abs(location.longitude - 2.2945) < 0.0001)
    }

    @Test func correctingTheCaptureDateWritesTheSidecarAndLeavesTheImageAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderLibrarySourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("clock.jpg")
        let context = try #require(CGContext(data: nil, width: 12, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 6))
        let exif: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:29 14:03:12", kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
        ]]
        let destination = try #require(CGImageDestinationCreateWithURL(image as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), exif as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let imageBytes = try Data(contentsOf: image)
        let shot = try #require(ISO8601DateFormatter().date(from: "2026-10-29T13:03:12Z"))

        let source = try makeSource(root: root)
        #expect(source.capabilities.contains(.captureDate))
        await source.load()
        await wait { source.assets.count == 1 && source.assets[0].creationDate == shot && !source.isScanning }
        let asset = try #require(source.assets.first)
        #expect(source.captureDate(for: asset) == shot)

        // The camera's clock was an hour late.
        let corrected = shot.addingTimeInterval(3600)
        try await source.setCaptureDate(corrected, for: asset)
        await wait { source.assets.first?.creationDate == corrected }
        #expect(source.assets.first?.creationDate == corrected)
        #expect(source.captureDate(for: asset) == corrected)
        #expect(try Sidecar.read(forImageAt: image)?.captureDate == corrected)
        #expect(try Data(contentsOf: image) == imageBytes, "the original is never rewritten")
        let details = await source.details(for: asset, allowingDownload: false)
        #expect(details.metadata?.captureDate == corrected)

        // A rescan reads the correction back from the sidecar, as after a catalog rebuild.
        source.rescan()
        await wait { !source.isScanning }
        #expect(source.captureDate(for: asset) == corrected)

        // Setting the file's own date again, as an undo does, removes the correction and the sidecar with it.
        try await source.setCaptureDate(shot, for: asset)
        await wait { source.assets.first?.creationDate == shot }
        #expect(source.captureDate(for: asset) == shot)
        #expect(try Sidecar.read(forImageAt: image) == nil)

        try await source.setCaptureDate(corrected, for: asset)
        try await source.setCaptureDate(nil, for: asset)
        #expect(source.captureDate(for: asset) == shot)
        #expect(try Sidecar.read(forImageAt: image) == nil)
    }

    @Test func detailsOfAnUnknownPhotoFallBackToTheListing() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root)
        let stranger = LibraryAsset(id: UUID().uuidString, pixelWidth: 30, pixelHeight: 20, creationDate: nil, isFavorite: false)
        let details = await source.details(for: stranger, allowingDownload: false)
        #expect(details == AssetDetails(stranger))
        #expect(details.fileName == nil && details.metadata?.pixelWidth == 30)
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

    @Test func flagsAndKeywordsRoundTripThroughTheSidecar() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root)
        await source.load()
        await wait { source.assets.count == 2 && !source.isScanning }
        let asset = try #require(source.assets.first)
        #expect(source.capabilities == [.rating, .flag, .keywords, .captureDate])

        try await source.setFlag(.rejected, for: asset)
        try await source.setKeywords([" lapland", "", "winter "], for: asset)
        await wait { source.assets.first { $0.id == asset.id }?.keywords == ["lapland", "winter"] }
        let updated = try #require(source.assets.first { $0.id == asset.id })
        #expect(updated.flag == .rejected && updated.keywords == ["lapland", "winter"])
        #expect(await source.keywords(for: updated) == ["lapland", "winter"])

        let sidecarName = try #require(try FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".qaama") })
        let sidecar = try #require(try Sidecar.read(forImageAt: root.appendingPathComponent(String(sidecarName.dropLast(6)))))
        #expect(sidecar.flag == .rejected && sidecar.keywords == ["lapland", "winter"])
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

@MainActor
private extension AssetCollection {
    /// `map` with an asynchronous transform, in order.
    func asyncMap<T>(_ transform: (LibraryAsset) async -> T) async -> [T] {
        var results: [T] = []
        for asset in self {
            await results.append(transform(asset))
        }
        return results
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
