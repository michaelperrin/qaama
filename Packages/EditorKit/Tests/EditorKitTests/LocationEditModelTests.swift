@testable import EditorKit
import Foundation
import ImageIOKit
import LibraryKit
import Testing

@MainActor
struct LocationEditModelTests {
    private let etretat = GeoCoordinate(latitude: 49.7073, longitude: 0.2036)
    private let paris = GeoCoordinate(latitude: 48.8584, longitude: 2.2945)

    /// Waits for an undo or redo, which writes in a task of its own.
    private func wait(until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A search that knows two places, and remembers what it was asked.
    private final class FakeSearch {
        var asked: [(text: String, near: GeoCoordinate?)] = []
        var failure: (any Error)?

        func callAsFunction(_ text: String, near: GeoCoordinate?) throws -> [PlaceSuggestion] {
            asked.append((text, near))
            if let failure {
                throw failure
            }
            return [
                PlaceSuggestion(title: "Étretat", subtitle: "Seine-Maritime, France", coordinate: GeoCoordinate(latitude: 49.7073, longitude: 0.2036)),
                PlaceSuggestion(title: "Étretat Cliffs", subtitle: "France", coordinate: GeoCoordinate(latitude: 49.71, longitude: 0.19)),
            ]
        }
    }

    private func makeModel(_ search: FakeSearch = FakeSearch()) -> LocationEditModel {
        LocationEditModel(searchDelay: .zero) { text, near in try search(text, near: near) }
    }

    @Test func showsTheLocationThePhotosShare() {
        // In the sample library, photos 0 and 10 were "taken" in Paris, photo 1 nowhere, photo 2 in Lyon.
        let source = SampleLibrarySource(count: 12)
        let model = makeModel()
        model.show([source.assets[0]], in: source)
        #expect(model.location == paris && !model.isMixed)
        model.show([source.assets[0], source.assets[10]], in: source)
        #expect(model.location == paris && !model.isMixed)
        model.show([source.assets[1]], in: source)
        #expect(model.location == nil && !model.isMixed)
        model.show([source.assets[0], source.assets[2]], in: source)
        #expect(model.location == nil && model.isMixed)
        model.show([source.assets[0], source.assets[1]], in: source)
        #expect(model.location == nil && model.isMixed, "a photo without a place differs from one with")
    }

    @Test func assigningIsOneUndoableStepForEveryPhotoShown() async {
        let source = SampleLibrarySource(count: 4)
        let photos = [source.assets[1], source.assets[2]]
        let before = photos.map { source.location(for: $0) }
        let model = makeModel()
        model.show(photos, in: source)
        let manager = UndoManager()
        manager.groupsByEvent = false

        manager.beginUndoGrouping()
        await model.assign(etretat, undoManager: manager)
        manager.endUndoGrouping()
        #expect(photos.allSatisfy { source.location(for: $0) == etretat })
        #expect(source.location(for: source.assets[0]) == paris, "a photo not shown keeps its place")
        #expect(model.location == etretat && !model.isMixed && model.lastAssigned == etretat)
        #expect(manager.undoActionName == "Assign Location")

        manager.undo()
        await wait { photos.map { source.location(for: $0) } == before }
        #expect(photos.map { source.location(for: $0) } == before)
        manager.redo()
        await wait { photos.allSatisfy { source.location(for: $0) == etretat } }
        #expect(photos.allSatisfy { source.location(for: $0) == etretat })

        // Already there: nothing written, nothing to undo.
        let idle = UndoManager()
        model.show(photos, in: source)
        await model.assign(etretat, undoManager: idle)
        #expect(!idle.canUndo)
    }

    @Test func theJPEGTwinGoesWithItsRAW() async throws {
        let source = SampleLibrarySource(count: 3, pairsFirstTwo: true)
        let raw = source.assets[0]
        let twinID = try #require(raw.pairedAssetID)
        let twin = try #require(source.asset(id: twinID))
        let model = makeModel()
        model.show([raw], in: source)
        await model.assign(etretat, undoManager: nil)
        #expect(source.location(for: raw) == etretat && source.location(for: twin) == etretat)
    }

    @Test func searchesWhatIsTypedNearThePhotoAndPicksAResult() async {
        let search = FakeSearch()
        let source = SampleLibrarySource(count: 2)
        let model = makeModel(search)
        model.show([source.assets[0]], in: source)
        model.isEditing = true

        model.query = "etretat"
        await model.searchSettled()
        #expect(search.asked.count == 1 && search.asked.first?.text == "etretat" && search.asked.first?.near == paris)
        #expect(model.suggestions.map(\.title) == ["Étretat", "Étretat Cliffs"])
        #expect(model.highlightedID == model.suggestions.first?.id, "Return picks the best match")
        model.moveHighlight(by: 1)
        model.moveHighlight(by: 1)
        #expect(model.highlightedID == model.suggestions.last?.id, "stays on the last result")
        model.moveHighlight(by: -1)

        await model.assign(GeoCoordinate(latitude: 48.86, longitude: 2.3), undoManager: nil)
        #expect(model.focus == paris, "a pin moved on the map leaves the framing alone")
        await model.pickHighlighted(undoManager: nil)
        #expect(source.location(for: source.assets[0]) == etretat)
        #expect(model.focus == etretat, "a place found by name is brought into view")
        #expect(model.query.isEmpty && model.suggestions.isEmpty, "the search is done with")

        // Blank text asks nothing.
        model.query = "   "
        await model.searchSettled()
        #expect(search.asked.count == 1 && model.suggestions.isEmpty && !model.isSearching)
    }

    @Test func aFailedSearchSaysWhy() async {
        let search = FakeSearch()
        search.failure = LibrarySourceError.assetUnavailable
        let source = SampleLibrarySource(count: 1)
        let model = makeModel(search)
        model.show([source.assets[0]], in: source)
        model.query = "nowhere"
        await model.searchSettled()
        #expect(model.suggestions.isEmpty && model.errorMessage != nil && !model.isSearching)
    }

    @Test func anotherSelectionLeavesTheEditing() {
        let source = SampleLibrarySource(count: 3)
        let model = makeModel()
        model.show([source.assets[0]], in: source)
        model.isEditing = true
        model.show([source.assets[0]], in: source)
        #expect(model.isEditing, "the same photo, after a write or an undo")
        model.show([source.assets[1]], in: source)
        #expect(!model.isEditing)
    }

    @Test func aPhotoWithoutAPlaceStartsWhereTheLastOneWasPut() async {
        let source = SampleLibrarySource(count: 4)
        let model = makeModel()
        model.show([source.assets[1]], in: source)
        #expect(model.startingPoint == nil)
        await model.assign(etretat, undoManager: nil)
        model.show([source.assets[3]], in: source)
        #expect(model.location == nil && model.startingPoint == etretat)
    }

    @Test func aSourceThatCannotStoreLocationsSaysSo() async {
        let source = SampleLibrarySource(count: 2)
        source.capabilities = [.rating]
        let model = makeModel()
        model.show([source.assets[1]], in: source)
        await model.assign(etretat, undoManager: nil)
        #expect(model.errorMessage != nil)
        #expect(model.location == nil, "back to what the source holds")
    }

    @Test func removingAndRevertingAreEachOneUndoableStep() async throws {
        // Photo 0 was "taken" in Paris, photo 2 in Lyon; the twin of a RAW follows.
        let source = SampleLibrarySource(count: 4, pairsFirstTwo: true)
        let photos = [source.assets[0], source.assets[2]]
        let twinID = try #require(photos[0].pairedAssetID)
        let twin = try #require(source.asset(id: twinID))
        let model = makeModel()
        model.show(photos, in: source)
        #expect(model.isMixed && model.canRemove && !model.canRevert)
        let manager = UndoManager()
        manager.groupsByEvent = false

        manager.beginUndoGrouping()
        await model.remove(undoManager: manager)
        manager.endUndoGrouping()
        #expect(photos.allSatisfy { source.location(for: $0) == nil })
        #expect(model.location == nil && !model.isMixed && !model.canRemove && model.canRevert)
        #expect(manager.undoActionName == "Remove Location")

        manager.beginUndoGrouping()
        await model.assign(etretat, undoManager: manager)
        manager.endUndoGrouping()
        #expect(source.location(for: twin) == etretat)
        manager.beginUndoGrouping()
        await model.revert(undoManager: manager)
        manager.endUndoGrouping()
        #expect(source.location(for: photos[0]) == paris && source.location(for: twin) == nil, "each back to its own file's")
        #expect(model.isMixed && !model.canRevert)
        #expect(manager.undoActionName == "Revert to Original Location")

        manager.undo()
        await wait { photos.allSatisfy { source.location(for: $0) == etretat } }
        #expect(photos.allSatisfy { source.location(for: $0) == etretat })
    }
}
