import Foundation
@testable import LibraryKit
import Testing

@MainActor
struct PhotosTrashTests {
    /// One change as the window's undo manager groups it: one step of the Edit menu.
    private func step(_ manager: UndoManager, _ change: () -> Void) {
        manager.beginUndoGrouping()
        change()
        manager.endUndoGrouping()
    }

    private func manager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    @Test func notesTheDeletedPhotosOnce() {
        let trash = PhotosTrash()
        let first = Date(timeIntervalSince1970: 100)
        trash.trash(["a", "b"], at: first, undoManager: nil)
        let version = trash.version
        trash.trash(["b", "c"], at: Date(timeIntervalSince1970: 200), undoManager: nil)
        #expect(trash.ids == ["a", "b", "c"])
        #expect(trash.photos.map(\.id) == ["a", "b", "c"], "in the order they were deleted")
        #expect(trash.photos[1].deletedAt == first, "deleted again, a photo keeps its date")
        #expect(trash.version > version)

        // Nothing new: no change for the listings to follow.
        let unchanged = trash.version
        trash.trash(["a"], undoManager: nil)
        trash.restore(["missing"], undoManager: nil)
        #expect(trash.version == unchanged)

        trash.restore(["a", "c"], undoManager: nil)
        #expect(trash.ids == ["b"])
    }

    @Test func deletingIsOneUndoableStep() {
        let trash = PhotosTrash()
        let manager = manager()
        step(manager) { trash.trash(["a", "b"], undoManager: manager) }
        #expect(manager.undoActionName == "Delete Photos")
        step(manager) { trash.trash(["c"], undoManager: manager) }
        #expect(manager.undoActionName == "Delete Photo")

        manager.undo()
        #expect(trash.ids == ["a", "b"] && manager.redoActionName == "Delete Photo")
        manager.undo()
        #expect(trash.ids.isEmpty && !manager.canUndo)
        manager.redo()
        manager.redo()
        #expect(trash.ids == ["a", "b", "c"] && manager.undoActionName == "Delete Photo")
    }

    @Test func restoringIsOneUndoableStepThatKeepsTheDates() {
        let trash = PhotosTrash()
        let manager = manager()
        let date = Date(timeIntervalSince1970: 100)
        trash.trash(["a", "b"], at: date, undoManager: nil)
        step(manager) { trash.restore(["a"], undoManager: manager) }
        #expect(trash.ids == ["b"] && manager.undoActionName == "Restore Photo")

        manager.undo()
        #expect(trash.ids == ["a", "b"] && trash.photos.allSatisfy { $0.deletedAt == date })
        manager.redo()
        #expect(trash.ids == ["b"])
    }

    @Test func aPhotoDeletedForGoodDoesNotComeBackWithUndo() {
        let trash = PhotosTrash()
        let manager = manager()
        step(manager) { trash.trash(["a", "b"], undoManager: manager) }
        // Deleted from the Photos library, from Recently Deleted.
        trash.forget(["a"])
        #expect(trash.ids == ["b"] && manager.undoActionName == "Delete Photos", "forgetting is no step of the Edit menu")

        manager.undo()
        #expect(trash.ids.isEmpty)
        manager.redo()
        #expect(trash.ids == ["b"], "only the photo the undo restored is deleted again")

        // Nothing left of the step: undoing it changes nothing, and leaves nothing to redo.
        trash.forget(["b"])
        manager.undo()
        #expect(trash.ids.isEmpty && !manager.canRedo)
    }

    @Test func comesBackFromItsFile() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("PhotosTrash.json")
        let trash = PhotosTrash(fileURL: file)
        await trash.load()
        #expect(trash.photos.isEmpty)
        trash.trash(["a", "b"], at: Date(timeIntervalSince1970: 100), undoManager: nil)
        trash.restore(["a"], undoManager: nil)
        await trash.settled()

        let reopened = PhotosTrash(fileURL: file)
        // Asked twice at once, as two libraries listed together do: both wait for the one reading.
        async let first: Void = reopened.load()
        async let second: Void = reopened.load()
        _ = await (first, second)
        #expect(reopened.photos == [TrashedPhoto(id: "b", deletedAt: Date(timeIntervalSince1970: 100))])
    }

    @Test func anUnreadableFileLeavesNothingDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("PhotosTrash.json")
        try Data("not json".utf8).write(to: file)
        let trash = PhotosTrash(fileURL: file)
        await trash.load()
        #expect(trash.ids.isEmpty)
    }

    @Test func theCatalogListsTheDeletedPhotosThroughASourceOfTheirOwn() throws {
        let catalog = try LibraryCatalog(store: CatalogStore.inMemory())
        #expect(catalog.recentlyDeleted !== catalog.photos && catalog.recentlyDeleted.listsTrash && !catalog.photos.listsTrash)
        #expect(catalog.recentlyDeleted.displayName == "Recently Deleted")
        #expect(catalog.recentlyDeleted.capabilities == [.deletion, .restoration], "a deleted photo is restored or deleted, not edited")
        #expect(!catalog.recentlyDeleted.hasPlaces)
        #expect(catalog.photos.capabilities.contains(.deletion) && !catalog.photos.capabilities.contains(.restoration))
    }
}
