import CoreGraphics
import LibraryKit
import Observation
import Testing

@MainActor
struct LibrarySourceNavigationTests {
    @Test func neighborStepsThroughTheListedPhotosAndStopsAtBothEnds() {
        let source = SampleLibrarySource(count: 4)
        let ids = source.assets.map(\.id)
        #expect(source.index(of: ids[2]) == 2)
        #expect(source.neighbor(of: ids[1], offset: 1) == ids[2])
        #expect(source.neighbor(of: ids[1], offset: -1) == ids[0])
        #expect(source.neighbor(of: ids[0], offset: -1) == nil)
        #expect(source.neighbor(of: ids[3], offset: 1) == nil)
        #expect(source.neighbor(of: "missing", offset: 1) == nil)
    }

    @Test func neighborFollowsTheQuery() {
        let source = SampleLibrarySource(count: 12)
        source.query.minimumRating = 4
        let listed = source.assets.map(\.id)
        #expect(listed.count >= 2)
        #expect(source.neighbor(of: listed[0], offset: 1) == listed[1])
        // A photo the query filters out has no place in the list, so no neighbors.
        let hidden = (0 ..< 12).map { "sample-\($0)" }.first { !listed.contains($0) }
        #expect(hidden.flatMap { source.neighbor(of: $0, offset: 1) } == nil)
    }

    @Test func aSelectionComesBackInTheOrderOfTheListing() {
        let source = SampleLibrarySource(count: 12)
        let listed = source.assets.map(\.id)
        // A set has no order of its own; whatever it yields, the photos come out as the grid shows them.
        let picked: Set<LibraryAsset.ID> = [listed[7], listed[0], listed[11], listed[3], "missing"]
        #expect(source.assets(withIDs: picked).map(\.id) == [listed[0], listed[3], listed[7], listed[11]])
        #expect(source.assets(withIDs: [listed[5], listed[2]]).map(\.id) == [listed[2], listed[5]])
        // The other way round once the listing is: the order follows the sort in place.
        source.query.ascending = true
        #expect(source.assets(withIDs: picked).map(\.id) == [listed[11], listed[7], listed[3], listed[0]])
        // A photo the query no longer lists stays, after those it does list.
        source.query = .default
        source.query.minimumRating = 4
        let kept = Set(source.assets.map(\.id))
        let mixed = source.assets(withIDs: Set(listed.prefix(6))).map(\.id)
        #expect(Set(mixed) == Set(listed.prefix(6)))
        #expect(Array(mixed.prefix { kept.contains($0) }) == source.assets.map(\.id).filter { listed.prefix(6).contains($0) })
        #expect(source.assets(withIDs: []).isEmpty)
    }

    @Test func theSampleLibraryHasATimelineWhenSortedByCaptureDate() throws {
        // Forty photos ten days apart, newest first: over a year of months.
        let source = SampleLibrarySource(count: 40, daysApart: 10)
        let timeline = try #require(source.timeline)
        #expect(timeline.count == 40)
        #expect(timeline.isComplete)
        #expect(timeline.sections.count >= 13)
        #expect(timeline.years.first == 2023)
        // A filter keeps the timeline in step with what is listed.
        source.query.favoritesOnly = true
        #expect(source.timeline?.count == source.assets.count)
        source.query.sort = .rating
        #expect(source.timeline == nil)
    }

    @Test func sourcesWithoutDatesHaveNoTimeline() {
        final class Bare: LibrarySource {
            let displayName = "Bare"
            let assets = AssetCollection.empty
            let lastLoadDuration: Duration? = nil
            let capabilities: Set<LibraryCapability> = []
            var query = LibraryQuery.default
            let queryCapabilities: Set<QueryCapability> = []
            func asset(id _: LibraryAsset.ID) -> LibraryAsset? {
                nil
            }

            func load() async {}
            func thumbnail(for _: LibraryAsset, pixelSize _: CGSize, fit _: ThumbnailFit) async -> CGImage? {
                nil
            }

            func fullSizeImage(for _: LibraryAsset) async -> CGImage? {
                nil
            }

            func setRating(_: Int, for _: LibraryAsset) async throws {}
            func editingInput(for _: LibraryAsset) async throws -> EditingInput {
                throw LibrarySourceError.assetUnavailable
            }

            func saveEdit(_: EditingOutput, for _: LibraryAsset) async throws {}
        }
        #expect(Bare().timeline == nil)
    }
}
