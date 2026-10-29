import Testing
@testable import LibraryKit

struct LibraryAssetTests {
    @Test func aspectRatioFromPixelDimensions() {
        let asset = LibraryAsset(id: "a", pixelWidth: 6000, pixelHeight: 4000, creationDate: nil, isFavorite: false)
        #expect(asset.aspectRatio == 1.5)
    }

    @Test func aspectRatioFallsBackToSquareWhenUnknown() {
        let asset = LibraryAsset(id: "b", pixelWidth: 0, pixelHeight: 0, creationDate: nil, isFavorite: false)
        #expect(asset.aspectRatio == 1)
    }
}
