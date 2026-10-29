@testable import LibraryKit
import Testing

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

struct LibraryAssetRatingTests {
    @Test func ratingIsClampedToZeroThroughFive() {
        #expect(LibraryAsset(id: "a", pixelWidth: 1, pixelHeight: 1, creationDate: nil, isFavorite: false, rating: 9).rating == 5)
        #expect(LibraryAsset(id: "b", pixelWidth: 1, pixelHeight: 1, creationDate: nil, isFavorite: false, rating: -1).rating == 0)
        #expect(LibraryAsset(id: "c", pixelWidth: 1, pixelHeight: 1, creationDate: nil, isFavorite: false, rating: 3).rating == 3)
    }
}
