import Foundation
import ImageIOKit
@testable import LibraryKit
import Testing

@MainActor
struct FilterPresetStoreTests {
    private var settings: LibraryFilterSettings {
        var settings = LibraryFilterSettings(now: Date(timeIntervalSince1970: 1_800_000_000))
        settings.filtersRating = true
        settings.rating = RatingFilter(.atLeast, 4)
        settings.filtersPlace = true
        settings.place = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
        settings.placeName = "Paris"
        return settings
    }

    /// One change as the window's undo manager groups it: one step of the Edit menu.
    private func step(_ manager: UndoManager, _ change: () -> Void) {
        manager.beginUndoGrouping()
        change()
        manager.endUndoGrouping()
    }

    @Test func listsThePresetsByName() {
        let store = FilterPresetStore()
        store.add(named: "Paris 4 stars", library: .photos, settings: settings, undoManager: nil)
        store.add(named: "best of 10", library: .photos, settings: settings, undoManager: nil)
        let folder = UUID()
        let second = store.add(named: " Best of 2 ", library: .folder(id: folder, path: "Trip"), settings: settings, undoManager: nil)
        #expect(store.presets.map(\.name) == ["Best of 2", "best of 10", "Paris 4 stars"])
        #expect(store.preset(id: second.id)?.library == .folder(id: folder, path: "Trip"))

        store.rename(second.id, to: "Zoo", undoManager: nil)
        #expect(store.presets.map(\.name) == ["best of 10", "Paris 4 stars", "Zoo"])
        store.delete(second.id, undoManager: nil)
        #expect(store.presets.count == 2 && store.preset(id: second.id) == nil)
    }

    @Test func aPresetIsSavedWithItsSwitchOnAndAName() {
        let store = FilterPresetStore()
        var parked = settings
        parked.isEnabled = false
        let preset = store.add(named: "  ", library: .photosAlbum(id: "album"), settings: parked, undoManager: nil)
        #expect(preset.name == "Untitled Filter")
        #expect(preset.settings.isEnabled && preset.settings.filters().rating == RatingFilter(.atLeast, 4))
        store.rename(preset.id, to: "", undoManager: nil)
        #expect(store.preset(id: preset.id)?.name == "Untitled Filter")
    }

    @Test func comesBackFromItsFile() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("FilterPresets.json")
        let store = FilterPresetStore(fileURL: file)
        await store.load()
        #expect(store.presets.isEmpty && store.isLoaded)
        let kept = store.add(named: "Paris", library: .photos, settings: settings, undoManager: nil)
        let dropped = store.add(named: "Dropped", library: .folder(id: UUID(), path: nil), settings: settings, undoManager: nil)
        store.delete(dropped.id, undoManager: nil)
        await store.settled()

        let reopened = FilterPresetStore(fileURL: file)
        await reopened.load()
        #expect(reopened.presets == [kept])
        #expect(reopened.presets.first?.settings == kept.settings, "stars, place and its name included")
    }

    @Test func anUnreadableFileLeavesNoPreset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("FilterPresets.json")
        try Data("not json".utf8).write(to: file)
        let store = FilterPresetStore(fileURL: file)
        await store.load()
        #expect(store.presets.isEmpty)
    }

    @Test func eachChangeIsOneUndoableStep() throws {
        let store = FilterPresetStore()
        let manager = UndoManager()
        manager.groupsByEvent = false
        var preset: FilterPreset?
        step(manager) { preset = store.add(named: "Paris", library: .photos, settings: settings, undoManager: manager) }
        let id = try #require(preset?.id)
        #expect(manager.undoActionName == "Save Filter Preset")
        step(manager) { store.rename(id, to: "Paris, 4 stars", undoManager: manager) }
        step(manager) { store.delete(id, undoManager: manager) }
        #expect(store.presets.isEmpty && manager.undoActionName == "Delete Filter Preset")

        manager.undo()
        #expect(store.preset(id: id)?.name == "Paris, 4 stars", "the same preset is back, for the sidebar to select again")
        manager.undo()
        #expect(store.preset(id: id)?.name == "Paris")
        manager.undo()
        #expect(store.presets.isEmpty && !manager.canUndo)
        manager.redo()
        manager.redo()
        #expect(store.preset(id: id)?.name == "Paris, 4 stars" && manager.redoActionName == "Delete Filter Preset")
    }

    @Test func updatingAPresetKeepsItsNameAndItsLibrary() {
        let store = FilterPresetStore()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let preset = store.add(named: "Paris", library: .photosAlbum(id: "album"), settings: settings, undoManager: nil)
        var changed = settings
        changed.rating = RatingFilter(.exactly, 5)
        changed.isEnabled = false

        step(manager) { store.update(preset.id, settings: changed, undoManager: manager) }
        let updated = store.preset(id: preset.id)
        #expect(updated?.name == "Paris" && updated?.library == .photosAlbum(id: "album"))
        #expect(updated?.settings.rating == RatingFilter(.exactly, 5) && updated?.settings.isEnabled == true)
        #expect(manager.undoActionName == "Update Filter Preset")

        // The same settings again are no step of the Edit menu.
        store.update(preset.id, settings: changed, undoManager: manager)
        manager.undo()
        #expect(store.preset(id: preset.id)?.settings == settings && !manager.canUndo)
    }

    @Test func aPresetShowsAViewOfItsLibraryThatIsItsOwn() throws {
        let catalog = try LibraryCatalog(store: CatalogStore.inMemory())
        let preset = catalog.filterPresets.add(named: "Paris", library: .photos, settings: settings, undoManager: nil)
        let library = try #require(catalog.library(for: preset))
        #expect(library.source !== catalog.photos, "filtering it leaves the Photos entry alone")
        #expect(library.source.query.filters == settings.filters() && catalog.photos.query.isUnfiltered)
        #expect(catalog.library(for: preset)?.source === library.source, "kept while the preset lives")

        // A library that is gone has nothing to show.
        let orphan = catalog.filterPresets.add(named: "Gone", library: .folder(id: UUID(), path: nil), settings: settings, undoManager: nil)
        #expect(catalog.library(for: orphan) == nil)
        let album = catalog.filterPresets.add(named: "Album", library: .photosAlbum(id: "missing"), settings: settings, undoManager: nil)
        #expect(catalog.library(for: album) == nil)
    }
}
