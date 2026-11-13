import CoreGraphics
import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

@MainActor
struct PhotoMapModelTests {
    private static let france = GeoRegion(south: 41, west: -6, north: 52, east: 9)

    /// Twelve photos, six of them placed: two in Paris, one each in Lyon, Marseille, Bordeaux and Brest.
    private func loadedModel(_ source: SampleLibrarySource) async -> PhotoMapModel {
        let model = PhotoMapModel()
        await model.load(from: source)
        return model
    }

    @Test func showsNothingUntilPhotosAreLoadedAndARegionIsShown() async {
        let source = SampleLibrarySource()
        let model = PhotoMapModel()
        model.show(region: Self.france, worldWidth: 20000, spacing: 90)
        #expect(model.clusters.isEmpty && model.locatedCount == nil && model.extent == nil)

        await model.load(from: source)
        await model.waitUntilSettled()
        #expect(model.locatedCount == 6)
        // The region asked for before the photos were there is the one grouped.
        #expect(model.clusters.map(\.count).sorted() == [1, 1, 1, 1, 2])
        let extent = try? #require(model.extent)
        #expect(extent.map { $0.west < -4 && $0.east > 5 && $0.south < 43.5 && $0.north > 48.8 } == true)
    }

    @Test func groupsFollowTheZoomAndTheRegion() async {
        let model = await loadedModel(SampleLibrarySource())

        // The whole world narrower than two thumbnails: one group for everything.
        model.show(region: GeoRegion(south: -80, west: -180, north: 80, east: 180), worldWidth: 150, spacing: 90)
        await model.waitUntilSettled()
        #expect(model.clusters.map(\.count) == [6])

        model.show(region: GeoRegion(south: 48, west: 1, north: 49.5, east: 3.5), worldWidth: 20000, spacing: 90)
        await model.waitUntilSettled()
        #expect(model.clusters.map(\.count) == [2])
        #expect(model.clusters.first.map { model.assetIDs(in: $0).sorted() } == ["sample-0", "sample-10"])
    }

    @Test func theMapFollowsTheFiltersOfTheListing() async {
        let source = SampleLibrarySource()
        let model = await loadedModel(source)
        model.show(region: Self.france, worldWidth: 20000, spacing: 90)

        // Favorites: photos 0, 5 and 10, of which 0 and 10 are in Paris.
        source.query.favoritesOnly = true
        await model.load(from: source)
        await model.waitUntilSettled()
        #expect(model.locatedCount == 2)
        #expect(model.clusters.map(\.count) == [2])
    }

    @Test func neitherTheSortNorAGroupPickedOnTheMapChangesItsContent() async {
        let source = SampleLibrarySource()
        let content = PhotoMapModel.Content(source)

        source.query.sort = .rating
        source.query.onlyAssetIDs = ["sample-0", "sample-10"]
        #expect(PhotoMapModel.Content(source) == content)
        // The grid shows the group; the map still knows every placed photo of the listing.
        #expect(source.assets.count == 2)
        #expect(await source.locatedAssets().count == 6)

        source.query.minimumRating = 3
        #expect(PhotoMapModel.Content(source) != content)
    }

    @Test func aChangeOfThePhotosIsLoadedAgain() async throws {
        let source = SampleLibrarySource()
        let model = await loadedModel(source)
        source.query.minimumRating = 4
        await model.load(from: source)
        // Ratings follow the number modulo 6: photos 4 and 10 are placed and rated 4.
        #expect(model.locatedCount == 2)

        try await source.setRating(5, for: #require(source.asset(id: "sample-0")))
        await model.load(from: source)
        #expect(model.locatedCount == 3)
    }

    // MARK: - Thumbnails

    /// Hands out thumbnails when told to, so a test decides what is loaded and when.
    @MainActor private final class CoverDesk {
        private var waiting: [LibraryAsset.ID: [CheckedContinuation<CGImage?, Never>]] = [:]
        private(set) var requests: [LibraryAsset.ID] = []
        let image = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!

        func load(_ id: LibraryAsset.ID) async -> CGImage? {
            requests.append(id)
            return await withCheckedContinuation { waiting[id, default: []].append($0) }
        }

        /// Delivers every thumbnail asked so far, or only that of `id`; nil stands for a photo that is gone.
        func deliver(_ id: LibraryAsset.ID? = nil, image: CGImage?? = nil) {
            for key in waiting.keys where id == nil || key == id {
                waiting.removeValue(forKey: key)?.forEach { $0.resume(returning: image ?? self.image) }
            }
        }
    }

    private static let world = GeoRegion(south: -80, west: -180, north: 80, east: 180)

    /// Lets the tasks that were just resumed run.
    private func pause() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func theGroupsOnScreenStayUntilTheThumbnailsOfTheNewOnesAreLoaded() async {
        let desk = CoverDesk()
        let model = PhotoMapModel(patience: .seconds(60)) { await desk.load($0) }
        await model.load(from: SampleLibrarySource())
        model.show(region: Self.world, worldWidth: 150, spacing: 90)
        await pause()
        // Nothing to keep on screen yet, and nothing shown without its thumbnail either.
        #expect(model.clusters.isEmpty && desk.requests == ["sample-0"])
        desk.deliver()
        await pause()
        #expect(model.clusters.map(\.count) == [6])
        let world = model.clusters

        // Zooming in splits the group in five: it stays until all five thumbnails are there.
        model.show(region: Self.france, worldWidth: 20000, spacing: 90)
        await pause()
        #expect(model.clusters == world)
        // The thumbnail already loaded isn't asked again.
        #expect(desk.requests.sorted() == ["sample-0", "sample-2", "sample-4", "sample-6", "sample-8"])
        desk.deliver("sample-2")
        await pause()
        #expect(model.clusters == world)
        desk.deliver()
        await pause()
        #expect(model.clusters.count == 5)
        #expect(model.clusters.allSatisfy { model.cover(of: $0) != nil })

        // Zooming back out: the thumbnail is still there, the groups change at once.
        model.show(region: Self.world, worldWidth: 150, spacing: 90)
        #expect(model.clusters == world)
    }

    @Test func aSlowThumbnailDoesNotHoldTheMapBackForLong() async {
        let desk = CoverDesk()
        let model = PhotoMapModel(patience: .milliseconds(400)) { await desk.load($0) }
        await model.load(from: SampleLibrarySource())
        model.show(region: Self.france, worldWidth: 20000, spacing: 90)
        await pause()
        desk.deliver("sample-0")
        await pause()
        #expect(model.clusters.isEmpty)

        // Past the patience, the groups show; the thumbnails that come later fill them in.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(model.clusters.count == 5)
        #expect(model.clusters.count(where: { model.cover(of: $0) != nil }) == 1)
        desk.deliver()
        await pause()
        #expect(model.clusters.allSatisfy { model.cover(of: $0) != nil })
    }

    @Test func aPhotoWithoutThumbnailDoesNotHoldItsGroupBack() async {
        let desk = CoverDesk()
        let model = PhotoMapModel(patience: .seconds(60)) { await desk.load($0) }
        await model.load(from: SampleLibrarySource())
        model.show(region: Self.world, worldWidth: 150, spacing: 90)
        await pause()
        desk.deliver(image: .some(nil))
        await pause()

        #expect(model.clusters.map(\.count) == [6])
        #expect(model.clusters.first.map { model.cover(of: $0) == nil } == true)
    }

    @Test func thumbnailsComeFromTheSourceAndAreAskedAgainWhenThePhotosChange() async throws {
        let source = SampleLibrarySource()
        let model = await loadedModel(source)
        model.show(region: Self.france, worldWidth: 20000, spacing: 90)
        await model.waitUntilSettled()
        #expect(model.clusters.count == 5)
        #expect(model.clusters.allSatisfy { model.cover(of: $0) != nil })

        // An edit elsewhere: the groups keep their thumbnails while the new ones load.
        try await source.setRating(5, for: #require(source.asset(id: "sample-1")))
        await model.load(from: source)
        #expect(model.clusters.allSatisfy { model.cover(of: $0) != nil })
        await model.waitUntilSettled()
        #expect(model.clusters.count == 5)
    }
}
