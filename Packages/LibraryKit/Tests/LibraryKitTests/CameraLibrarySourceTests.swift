import CoreGraphics
import Foundation
@testable import LibraryKit
import Testing

@MainActor
struct CameraLibrarySourceTests {
    private func date(_ day: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86400)
    }

    private func makeSource() -> (CameraLibrarySource, FakeCameraConnection) {
        let connection = FakeCameraConnection()
        return (CameraLibrarySource(connection: connection), connection)
    }

    // MARK: - Listing

    @Test func aListingShowsRAWAndJPEGPairsAsOnePhotoAndMarksVideos() {
        let listing = CameraListing(files: [
            CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1)),
            CameraFile(id: "DCIM/100/IMG_0002.CR2", creationDate: date(2), isRAW: true),
            CameraFile(id: "DCIM/100/IMG_0002.JPG", creationDate: date(2)),
            CameraFile(id: "DCIM/100/MVI_0003.MOV", creationDate: date(3), isMovie: true),
            // Same name in another folder: not the twin of the RAW above.
            CameraFile(id: "DCIM/101/IMG_0002.JPG", creationDate: date(4)),
            CameraFile(id: "DCIM/100/IMG_0005.RAF", creationDate: nil, isRAW: true),
        ])
        // Newest first, the photo without a date last.
        // The video is listed with the photos, by date, and marked.
        #expect(listing.assets.map(\.id) == ["DCIM/101/IMG_0002.JPG", "DCIM/100/MVI_0003.MOV", "DCIM/100/IMG_0002.CR2", "DCIM/100/IMG_0001.JPG", "DCIM/100/IMG_0005.RAF"])
        #expect(listing.movieCount == 1)
        #expect(listing.assets.filter(\.isVideo).map(\.id) == ["DCIM/100/MVI_0003.MOV"])
        let raw = listing.assets[2]
        #expect(raw.isRAW)
        #expect(raw.pairedAssetID == "DCIM/100/IMG_0002.JPG")
        #expect(listing.assets[4].pairedAssetID == nil)
    }

    @Test func photosOfTheSameSecondKeepOneOrder() {
        let files = (0 ..< 6).map { CameraFile(id: "DCIM/100/IMG_000\($0).JPG", creationDate: date(0)) }
        #expect(CameraListing(files: files).assets.map(\.id) == CameraListing(files: files.reversed()).assets.map(\.id))
    }

    @Test func thePhotosAreListedOnceTheDeviceHasAnnouncedThemAll() async {
        let (source, connection) = makeSource()
        #expect(source.state == .idle)
        #expect(!connection.isOpen)
        await source.load()
        #expect(connection.isOpen)
        #expect(source.state == .listing)
        #expect(source.listingProgress == nil)

        // One file per event, in no order, as a card does: nothing is listed yet.
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", pixelWidth: 6000, pixelHeight: 4000, creationDate: date(1))]))
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0002.JPG", creationDate: date(40))]))
        connection.send(.added([CameraFile(id: "DCIM/100/MVI_0003.MOV", creationDate: date(40), isMovie: true)]))
        #expect(source.assets.isEmpty)
        // Too early to tell how many there will be.
        connection.send(.progress(0.02))
        #expect(source.listingProgress == nil)
        // A tenth of the files announced, two photos among them: about twenty to come.
        connection.send(.progress(0.1))
        #expect(source.listingProgress == IndexingProgress(done: 2, total: 20))
        #expect(source.assets.isEmpty)
        #expect(source.state == .listing)
        // What was found so far can be shown, in the order it came, the video left out.
        #expect(source.foundPhotos.map(\.id) == ["DCIM/100/IMG_0001.JPG", "DCIM/100/IMG_0002.JPG"])
        #expect(source.foundPhotos.first?.aspectRatio == 1.5)

        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0004.JPG", creationDate: date(41))]))
        connection.send(.listed)
        #expect(source.assets.filter { !$0.isVideo }.map(\.id) == ["DCIM/100/IMG_0004.JPG", "DCIM/100/IMG_0002.JPG", "DCIM/100/IMG_0001.JPG"])
        #expect(source.assets.count == 4)
        #expect(source.photoCount == 3)
        #expect(source.asset(id: "DCIM/100/IMG_0001.JPG")?.aspectRatio == 1.5)
        #expect(source.movieCount == 1)
        #expect(source.state == .listed)
        #expect(source.listingProgress == nil)
        #expect(source.foundPhotos.isEmpty)
        #expect(source.lastLoadDuration != nil)
        #expect(source.timeline?.count == 4)
        #expect(source.timeline?.sections.count == 2)

        // A photo taken while the camera is plugged in shows at once.
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0005.JPG", creationDate: date(42))]))
        #expect(source.assets.first?.id == "DCIM/100/IMG_0005.JPG")
        #expect(source.listingProgress == nil)
    }

    @Test func theNumberOfPhotosToExpectStaysPutWhileTheDeviceCounts() {
        // Nothing to go by yet.
        #expect(CameraLibrarySource.expectedCount(found: 0, fraction: 0, previous: nil) == nil)
        #expect(CameraLibrarySource.expectedCount(found: 30, fraction: 0.02, previous: nil) == nil)
        // The device's count runs ahead of its files at the start: 28 photos at 5 % of 1,233.
        #expect(CameraLibrarySource.expectedCount(found: 28, fraction: 0.05, previous: nil) == nil)
        // As measured on a card of 1,256 files: whole percents make the figure wobble.
        let first = CameraLibrarySource.expectedCount(found: 125, fraction: 0.1, previous: nil)
        #expect(first == 1250)
        #expect(CameraLibrarySource.expectedCount(found: 300, fraction: 0.25, previous: first) == 1250)
        #expect(CameraLibrarySource.expectedCount(found: 900, fraction: 0.71, previous: first) == 1250)
        // Clearly another figure: taken.
        #expect(CameraLibrarySource.expectedCount(found: 900, fraction: 0.5, previous: first) == 1800)
        // Never fewer than the photos already found.
        #expect(CameraLibrarySource.expectedCount(found: 1255, fraction: 0.99, previous: 1250) == 1268)
        #expect(CameraLibrarySource.expectedCount(found: 40, fraction: 1, previous: nil) == 40)
    }

    @Test func aFileRemovedFromTheDeviceLeavesTheListing() async {
        let (source, connection) = makeSource()
        await source.load()
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1)), CameraFile(id: "DCIM/100/IMG_0002.JPG", creationDate: date(2)),
                                CameraFile(id: "DCIM/100/IMG_0003.JPG", creationDate: date(3))]))
        // Before the photos are listed, and after.
        connection.send(.removed(["DCIM/100/IMG_0003.JPG"]))
        connection.send(.listed)
        #expect(source.assets.count == 2)
        connection.send(.removed(["DCIM/100/IMG_0002.JPG"]))
        #expect(source.assets.map(\.id) == ["DCIM/100/IMG_0001.JPG"])
        #expect(source.asset(id: "DCIM/100/IMG_0002.JPG") == nil)
    }

    @Test func aDeviceThatFailsOrLeavesSaysSo() async {
        let (source, connection) = makeSource()
        await source.load()
        connection.send(.failed("The card couldn't be opened."))
        #expect(source.state == .unavailable("The card couldn't be opened."))

        let (other, otherConnection) = makeSource()
        await other.load()
        otherConnection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1))]))
        otherConnection.send(.listed)
        other.disconnect()
        #expect(!otherConnection.isOpen)
        // What was listed stays to look at.
        #expect(other.assets.count == 1)
        if case .unavailable = other.state {} else {
            Issue.record("A device pulled out should be unavailable, not \(other.state)")
        }
    }

    @Test func photosAreDeletedFromTheDeviceForGoodAPairAsOne() async throws {
        let (source, connection) = makeSource()
        await source.load()
        // Nothing can be deleted before the device is listed.
        #expect(source.capabilities.isEmpty)
        connection.send(.added([
            CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1)),
            CameraFile(id: "DCIM/100/IMG_0002.CR2", creationDate: date(2), isRAW: true),
            CameraFile(id: "DCIM/100/IMG_0002.JPG", creationDate: date(2)),
            CameraFile(id: "DCIM/100/IMG_0003.JPG", creationDate: date(3)),
        ]))
        connection.send(.listed)
        #expect(source.capabilities == [.deletion])
        let raw = try #require(source.asset(id: "DCIM/100/IMG_0002.CR2"))
        #expect(source.deletionNotice(for: [raw])?.contains("can't be undone") == true)

        // No undo is registered: a card has no Trash to take a file back from.
        let undoManager = UndoManager()
        #expect(try await source.delete([raw], undoManager: undoManager))
        #expect(!undoManager.canUndo)
        #expect(connection.requests.last == "delete DCIM/100/IMG_0002.CR2, DCIM/100/IMG_0002.JPG")
        #expect(source.assets.map(\.id) == ["DCIM/100/IMG_0003.JPG", "DCIM/100/IMG_0001.JPG"])
        // The device telling the same a moment later changes nothing.
        connection.send(.removed(["DCIM/100/IMG_0002.CR2", "DCIM/100/IMG_0002.JPG"]))
        #expect(source.assets.count == 2)

        // A file the device refuses stays listed, and the failure is told.
        connection.undeletable = ["DCIM/100/IMG_0001.JPG"]
        await #expect(throws: LibrarySourceError.self) { try await source.delete(Array(source.assets), undoManager: nil) }
        #expect(source.assets.map(\.id) == ["DCIM/100/IMG_0001.JPG"])
    }

    @Test func aLockedCardOffersNoDeletion() async throws {
        let (source, connection) = makeSource()
        connection.canDelete = false
        await source.load()
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1))]))
        connection.send(.listed)
        #expect(source.capabilities.isEmpty)
        let asset = try #require(source.asset(id: "DCIM/100/IMG_0001.JPG"))
        await #expect(throws: LibrarySourceError.self) { try await source.delete([asset], undoManager: nil) }
        #expect(source.assets.count == 1)
    }

    @Test func aDeviceStoresNothingAboutItsPhotos() async {
        let (source, _) = makeSource()
        #expect(source.capabilities.isEmpty)
        #expect(source.queryCapabilities.isEmpty)
        let asset = LibraryAsset(id: "DCIM/100/IMG_0001.JPG", pixelWidth: 0, pixelHeight: 0, creationDate: nil, isFavorite: false)
        await #expect(throws: LibrarySourceError.self) { try await source.setRating(3, for: asset) }
        await #expect(throws: LibrarySourceError.self) { _ = try await source.editingInput(for: asset) }
    }

    // MARK: - Thumbnails

    @Test func theQuickThumbnailIsTheOneEmbeddedInTheHeadOfTheFile() async throws {
        let (source, connection) = makeSource()
        await source.load()
        let photo = CameraTestImages.jpeg(width: 1600, height: 1200, embeddingThumbnail: true)
        // The file is larger than what is read of it: the thumbnail must come from the head alone.
        #expect(photo.count > CameraThumbnails.headLength)
        connection.heads["DCIM/100/IMG_0001.JPG"] = photo
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1))]))
        connection.send(.listed)
        let asset = try #require(source.asset(id: "DCIM/100/IMG_0001.JPG"))

        let thumbnail = try #require(await source.quickThumbnail(for: asset))
        #expect(max(thumbnail.width, thumbnail.height) <= 320)
        #expect(connection.requests == ["head DCIM/100/IMG_0001.JPG"])
        // Kept: asking again doesn't go back to the device.
        #expect(await source.quickThumbnail(for: asset) != nil)
        #expect(connection.requests.count == 1)
    }

    @Test func theBandsAroundAnEmbeddedThumbnailAreCroppedAway() throws {
        // What a camera embeds for a 3:2 photo: 160 × 120, the photo in the middle 160 × 107.
        let context = try #require(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let embedded = try #require(context.makeImage())
        let landscape = CameraThumbnails.cropped(embedded, toAspectRatio: 1.5)
        #expect(landscape.width == 160)
        // 107 rows of photo, less one at each edge where the bands bleed.
        #expect(landscape.height == 104)
        // The shapes agree, or the photo's is unknown: nothing to crop.
        #expect(CameraThumbnails.cropped(embedded, toAspectRatio: 4.0 / 3.0).height == 120)
        #expect(CameraThumbnails.cropped(embedded, toAspectRatio: 0).height == 120)
        // A photo wider than tall in a taller thumbnail, and the reverse.
        let square = CameraThumbnails.cropped(embedded, toAspectRatio: 1)
        #expect(square.width == 118)
        #expect(square.height == 120)
    }

    @Test func aFileWithoutAnEmbeddedThumbnailHasNoQuickOne() async throws {
        let (source, connection) = makeSource()
        await source.load()
        connection.heads["DCIM/100/IMG_0001.JPG"] = CameraTestImages.jpeg(width: 1600, height: 1200, embeddingThumbnail: false)
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1))]))
        connection.send(.listed)
        let asset = try #require(source.asset(id: "DCIM/100/IMG_0001.JPG"))
        // Never a decode of the truncated image.
        #expect(await source.quickThumbnail(for: asset) == nil)
    }

    @Test func theQuickThumbnailOfAPairedRAWComesFromItsJPEG() async throws {
        let (source, connection) = makeSource()
        await source.load()
        connection.heads["DCIM/100/IMG_0001.JPG"] = CameraTestImages.jpeg(width: 800, height: 600, embeddingThumbnail: true)
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.CR2", creationDate: date(1), isRAW: true),
                                CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1))]))
        connection.send(.listed)
        let raw = try #require(source.asset(id: "DCIM/100/IMG_0001.CR2"))
        #expect(await source.quickThumbnail(for: raw) != nil)
        #expect(connection.requests == ["head DCIM/100/IMG_0001.JPG"])
    }

    @Test func theGridThumbnailIsAskedOfTheDeviceAtTheLongEdgeAndKept() async throws {
        let (source, connection) = makeSource()
        await source.load()
        connection.thumbnails["DCIM/100/IMG_0001.JPG"] = CameraTestImages.jpeg(width: 480, height: 320, embeddingThumbnail: false)
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", pixelWidth: 6000, pixelHeight: 4000, creationDate: date(1))]))
        connection.send(.listed)
        let asset = try #require(source.asset(id: "DCIM/100/IMG_0001.JPG"))

        let thumbnail = try #require(await source.thumbnail(for: asset, pixelSize: CGSize(width: 480, height: 320), fit: .fill))
        #expect(thumbnail.width == 480)
        #expect(thumbnail.height == 320)
        #expect(connection.requests == ["thumbnail DCIM/100/IMG_0001.JPG 480"])
        _ = await source.thumbnail(for: asset, pixelSize: CGSize(width: 480, height: 320), fit: .fill)
        #expect(connection.requests.count == 1)
        // Another size is another request.
        _ = await source.thumbnail(for: asset, pixelSize: CGSize(width: 960, height: 640), fit: .fill)
        #expect(connection.requests.last == "thumbnail DCIM/100/IMG_0001.JPG 960")
        // A photo the device doesn't list isn't asked for.
        let unknown = LibraryAsset(id: "DCIM/100/NOPE.JPG", pixelWidth: 0, pixelHeight: 0, creationDate: nil, isFavorite: false)
        #expect(await source.thumbnail(for: unknown, pixelSize: CGSize(width: 480, height: 320), fit: .fill) == nil)
        #expect(connection.requests.count == 2)
    }

    @Test func aPreviewIsAskedOnceAtAStepOfSizeAndKept() async throws {
        let (source, connection) = makeSource()
        await source.load()
        connection.thumbnails["DCIM/100/IMG_0001.JPG"] = CameraTestImages.jpeg(width: 480, height: 320, embeddingThumbnail: false)
        connection.send(.added([CameraFile(id: "DCIM/100/IMG_0001.JPG", creationDate: date(1))]))
        connection.send(.listed)
        let asset = try #require(source.asset(id: "DCIM/100/IMG_0001.JPG"))

        // A window 1,300 points wide on a 2x screen, then a little wider: the same request.
        #expect(CameraLibrarySource.previewPixels(forLongEdge: 2600) == 3072)
        #expect(CameraLibrarySource.previewPixels(forLongEdge: 2700) == 3072)
        #expect(CameraLibrarySource.previewPixels(forLongEdge: 300) == 1024)
        #expect(CameraLibrarySource.previewPixels(forLongEdge: 9000) == 4096)

        // Warmed in advance and asked for at the same time: the device is asked once.
        async let warmed = source.preview(for: asset, maxPixelSize: 3072)
        async let asked = source.preview(for: asset, maxPixelSize: 3072)
        let images = await [warmed, asked]
        #expect(images.allSatisfy { $0 != nil })
        #expect(connection.requests == ["thumbnail DCIM/100/IMG_0001.JPG 3072"])
        #expect(await source.preview(for: asset, maxPixelSize: 3072) != nil)
        #expect(connection.requests.count == 1)
        // The full-size image of a photo on a device is its largest preview.
        _ = await source.fullSizeImage(for: asset)
        #expect(connection.requests.last == "thumbnail DCIM/100/IMG_0001.JPG 4096")
    }

    // MARK: - Devices

    @Test func devicesAreListedWhileTheyArePluggedIn() async {
        let browser = FakeCameraBrowser()
        let devices = CameraDevices(browser: browser)
        #expect(!browser.isStarted)
        devices.start()
        #expect(browser.isStarted)
        #expect(devices.sources.isEmpty)

        let card = FakeCameraConnection(id: "card-1", name: "EOS_DIGITAL")
        browser.onConnect?(card)
        // Announced twice: listed once.
        browser.onConnect?(card)
        #expect(devices.sources.map(\.displayName) == ["EOS_DIGITAL"])
        let source = devices.source(id: "card-1")
        await source?.load()
        #expect(card.isOpen)

        browser.onDisconnect?("card-1")
        #expect(devices.sources.isEmpty)
        #expect(!card.isOpen)
        #expect(devices.source(id: "card-1") == nil)
    }

    @Test func withoutABrowserNoDeviceIsEverListed() {
        let devices = CameraDevices()
        devices.start()
        #expect(devices.sources.isEmpty)
    }
}
