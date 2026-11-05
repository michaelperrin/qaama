import LibraryKit
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
}
