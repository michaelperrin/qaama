import Foundation
@testable import LibraryKit
import Testing

@MainActor
struct AssetAlbumsModelTests {
    /// A library whose first photos are filed: sample-0 in two albums, sample-1 in one of them and
    /// another, sample-2 in none.
    private func makeSource() -> (SampleLibrarySource, [LibraryAsset]) {
        let source = SampleLibrarySource(count: 4)
        source.albumIDsByAsset = ["sample-0": ["iceland", "portfolio"], "sample-1": ["portfolio", "family"]]
        return (source, (0 ..< 4).compactMap { source.asset(id: "sample-\($0)") })
    }

    @Test func onePhotoShowsItsAlbums() async {
        let (source, assets) = makeSource()
        let model = AssetAlbumsModel()
        #expect(model.albumIDs == nil && !model.isShowing([assets[0]]))

        await model.show([assets[0]], in: source)
        #expect(model.albumIDs == ["iceland", "portfolio"])
        #expect(model.isShowing([assets[0]]) && !model.isShowing([assets[1]]))

        await model.show([assets[2]], in: source)
        #expect(model.albumIDs == [], "in no album: read, and empty")
    }

    @Test func severalPhotosShowTheAlbumsTheyAreAllIn() async {
        let (source, assets) = makeSource()
        let model = AssetAlbumsModel()

        await model.show([assets[0], assets[1]], in: source)
        #expect(model.albumIDs == ["portfolio"])

        await model.show([assets[0], assets[1], assets[2]], in: source)
        #expect(model.albumIDs == [])
    }

    @Test func nothingIsReadForALibraryWithoutAlbums() async throws {
        let source = SampleLibrarySource(count: 2)
        let asset = try #require(source.asset(id: "sample-0"))
        #expect(!source.hasAlbums(for: asset))

        let model = AssetAlbumsModel()
        await model.show([asset], in: source)
        #expect(model.albumIDs == [])
    }

    @Test func theSamePhotosKeepTheirAlbumsWhileTheyAreReadAgain() async {
        let (source, assets) = makeSource()
        let model = AssetAlbumsModel()
        await model.show([assets[0]], in: source)

        // A rating changes the photo handed in, not the photo shown.
        var rated = assets[0]
        rated.rating = 5
        source.albumIDsByAsset?["sample-0"] = ["iceland", "portfolio", "family"]
        let reading = Task { await model.show([rated], in: source) }
        // Lets the reading start: it now waits for the library's answer.
        await Task.yield()
        #expect(model.albumIDs == ["iceland", "portfolio"], "nothing blinks before the new answer")
        await reading.value
        #expect(model.albumIDs == ["iceland", "portfolio", "family"])
    }

    @Test func anotherSelectionEmptiesThePanelAtOnce() async {
        let (source, assets) = makeSource()
        let model = AssetAlbumsModel()
        await model.show([assets[0]], in: source)

        let reading = Task { await model.show([assets[1]], in: source) }
        await Task.yield()
        #expect(model.albumIDs == nil, "the albums of another photo aren't shown as this one's")
        await reading.value
        #expect(model.albumIDs == ["portfolio", "family"])

        await model.show([], in: source)
        #expect(model.albumIDs == nil && !model.isShowing([]))
    }

    @Test func aCancelledReadingLeavesNothingBehind() async {
        let (source, assets) = makeSource()
        let model = AssetAlbumsModel()
        let reading = Task { await model.show([assets[0], assets[1]], in: source) }
        reading.cancel()
        await reading.value
        #expect(model.albumIDs == nil)
    }
}
