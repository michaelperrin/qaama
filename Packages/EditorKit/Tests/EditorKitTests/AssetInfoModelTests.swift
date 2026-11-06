@testable import EditorKit
import Foundation
import LibraryKit
import Testing

@MainActor
struct AssetInfoModelTests {
    @Test func showsTheDetailsAndAHistogramOfThePhoto() async throws {
        let source = SampleLibrarySource(count: 3)
        let asset = try #require(source.assets.first)
        let model = AssetInfoModel()

        await model.show(asset, in: source)
        #expect(model.asset == asset)
        #expect(model.details?.fileName == "\(asset.id).jpg")
        #expect(model.details?.metadata?.pixelWidth == asset.pixelWidth)
        #expect(model.details?.metadata?.cameraModel == "Sample")
        let histogram = try #require(model.histogram)
        #expect(histogram.red.count == 256 && histogram.luminance.contains { $0 > 0 })
    }

    @Test func showingNothingClearsThePanel() async {
        let source = SampleLibrarySource(count: 2)
        let model = AssetInfoModel()
        await model.show(source.assets[0], in: source)
        #expect(model.asset != nil)

        await model.show(nil, in: source)
        #expect(model.asset == nil && model.details == nil && model.histogram == nil)
    }

    @Test func aPhotoNotLoadedYetShowsWhatTheListingKnows() async {
        let source = SampleLibrarySource(count: 2)
        let first = source.assets[0]
        let second = source.assets[1]
        let model = AssetInfoModel()
        #expect(model.details(for: first) == AssetDetails(first))

        await model.show(first, in: source)
        #expect(model.details(for: first).fileName == "\(first.id).jpg")
        // Selected but not loaded yet: never the previous photo's details under its name.
        #expect(model.details(for: second) == AssetDetails(second))
    }

    @Test func anAbandonedLoadLeavesThePanelToTheNextOne() async {
        let source = SampleLibrarySource(count: 2)
        let first = source.assets[0]
        let second = source.assets[1]
        let model = AssetInfoModel()

        // The selection moves on before the first photo's details came back.
        let abandoned = Task { await model.show(first, in: source) }
        abandoned.cancel()
        await abandoned.value
        await model.show(second, in: source)
        #expect(model.asset == second)
        #expect(model.details?.fileName == "\(second.id).jpg")
        #expect(model.histogram != nil)
    }

    @Test func anOriginalInCloudIsDownloadedOnlyOnRequest() async {
        let source = SampleLibrarySource(count: 2)
        let asset = source.assets[0]
        source.cloudOnlyIDs = [asset.id]
        let model = AssetInfoModel()

        await model.show(asset, in: source)
        #expect(model.details?.isOriginalInCloud == true)
        #expect(model.details?.metadata?.cameraModel == nil && model.details?.metadata?.pixelWidth == asset.pixelWidth)
        #expect(!model.isDownloadingOriginal)

        model.downloadOriginal(in: source)
        #expect(model.isDownloadingOriginal)
        await model.waitForDownload()
        #expect(!model.isDownloadingOriginal && !model.originalDownloadFailed)
        #expect(model.details?.isOriginalInCloud == false)
        #expect(model.details?.metadata?.cameraModel == "Sample")
    }

    @Test func movingToAnotherPhotoAbandonsTheDownload() async {
        let source = SampleLibrarySource(count: 2)
        let first = source.assets[0]
        let second = source.assets[1]
        source.cloudOnlyIDs = [first.id]
        let model = AssetInfoModel()
        await model.show(first, in: source)

        model.downloadOriginal(in: source)
        await model.show(second, in: source)
        #expect(!model.isDownloadingOriginal)
        #expect(model.asset == second && model.details?.fileName == "\(second.id).jpg")
        // Whatever the abandoned download brings back later stays out of the panel.
        await Task.yield()
        #expect(model.details?.fileName == "\(second.id).jpg" && model.details?.isOriginalInCloud == false)
    }
}
