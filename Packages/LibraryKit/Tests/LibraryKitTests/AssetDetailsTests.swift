import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

struct AssetDetailsTests {
    @Test func theListingAloneGivesDimensionsAndDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let details = AssetDetails(LibraryAsset(id: "a", pixelWidth: 6000, pixelHeight: 4000, creationDate: date, isFavorite: false))
        #expect(details.metadata == ImageMetadata(pixelWidth: 6000, pixelHeight: 4000, captureDate: date))
        #expect(details.fileName == nil && !details.isOriginalInCloud)
    }

    @Test func unknownDimensionsMeanNoMetadata() {
        let details = AssetDetails(LibraryAsset(id: "b", pixelWidth: 0, pixelHeight: 0, creationDate: .now, isFavorite: false))
        #expect(details.metadata == nil)
    }

    @Test func theCatalogAnswersOnlyOnceTheHeaderWasRead() {
        var item = CatalogItem(folderID: UUID(), relativePath: "Trip/DSCF0001.RAF", fileType: "com.fuji.raw-image", fileSize: 1,
                               contentModified: Date(timeIntervalSince1970: 1_700_000_000), isRAW: true)
        #expect(ImageMetadata(item) == nil)

        let header = ImageMetadata(pixelWidth: 6240, pixelHeight: 4160, orientation: 6, captureDate: Date(timeIntervalSince1970: 1_699_000_000),
                                   cameraMake: "FUJIFILM", cameraModel: "X-T5", lens: "XF35mmF2 R WR", iso: 400, exposureTime: 0.004,
                                   aperture: 2.8, focalLength: 35)
        item.apply(header)
        item.metadataRead = item.contentModified.addingTimeInterval(60)
        #expect(ImageMetadata(item) == header)

        // The file changed since: what the catalog holds describes the previous version.
        item.contentModified = item.contentModified.addingTimeInterval(3600)
        #expect(ImageMetadata(item) == nil)
    }

    @Test func aHeaderThatCouldNotBeReadGivesNoMetadata() {
        var item = CatalogItem(folderID: UUID(), relativePath: "broken.jpg", fileType: "public.jpeg", fileSize: 1, contentModified: .distantPast)
        item.metadataRead = .now
        #expect(ImageMetadata(item) == nil)
    }
}
