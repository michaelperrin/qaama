import Foundation
@testable import LibraryKit
import Testing

@MainActor
struct PhotosAlbumEditorTests {
    /// An editor on an empty library, with settings of its own so the last album doesn't leak between tests.
    private func makeEditor(_ library: FakeAlbumLibrary = FakeAlbumLibrary()) -> (PhotosAlbumEditor, FakeAlbumLibrary, UserDefaults, String) {
        let suite = "PhotosAlbumEditorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PhotosAlbumEditor(library: library, defaults: defaults), library, defaults, suite)
    }

    /// An undo manager that groups by hand: tests have no run loop to close an event's group.
    private func makeUndoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    /// Makes a change as one undo group, as an event of the run loop would.
    @discardableResult
    private func step<T>(_ manager: UndoManager, _ change: () async throws -> T) async rethrows -> T {
        manager.beginUndoGrouping()
        defer { manager.endUndoGrouping() }
        return try await change()
    }

    @Test func creatingAnAlbumWithPhotosIsUndoneByDeletingItAndRedoneAsANewAlbum() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeUndoManager()

        let id = try await step(manager) {
            try await editor.createAlbum(titled: "Iceland", containing: ["a", "b"], undoManager: manager)
        }
        #expect(await library.albums[id] == PhotosAlbumContent(title: "Iceland", assetIDs: ["a", "b"]))
        #expect(editor.lastAlbumID == id, "an album created from photos is where the next ones go")
        #expect(manager.undoActionName == "New Album")

        manager.undo()
        await editor.waitUntilIdle()
        #expect(await library.albums.isEmpty)
        #expect(manager.redoActionName == "New Album")

        manager.redo()
        await editor.waitUntilIdle()
        let again = try #require(await library.albumID(titled: "Iceland"))
        #expect(again != id, "Photos gives a new identifier")
        #expect(await library.assetIDs(inAlbum: again) == ["a", "b"])
        #expect(editor.lastAlbumID == again, "the last album follows the album created again")

        // And the redo can be undone in turn, on the new identifier.
        manager.undo()
        await editor.waitUntilIdle()
        #expect(await library.albums.isEmpty)
    }

    @Test func anEmptyAlbumDoesNotBecomeTheLastAlbum() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try await editor.createFolder(titled: "Trips", undoManager: nil)
        let id = try await editor.createAlbum(titled: "Empty", inFolder: folder, undoManager: nil)
        #expect(await library.albums[id]?.folderID == folder)
        #expect(editor.lastAlbumID == nil)
    }

    @Test func addingPhotosSkipsThoseAlreadyThereAndUndoOnlyTakesOutWhatWasAdded() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = try await editor.createAlbum(titled: "Best of", containing: ["a"], undoManager: nil)
        let manager = makeUndoManager()

        let added = try await step(manager) { try await editor.add(["a", "b", "c"], toAlbum: id, undoManager: manager) }
        #expect(added == 2)
        #expect(await library.assetIDs(inAlbum: id) == ["a", "b", "c"])
        #expect(manager.undoActionName == "Add to Album")

        manager.undo()
        await editor.waitUntilIdle()
        #expect(await library.assetIDs(inAlbum: id) == ["a"], "the photo that was already in the album stays")

        manager.redo()
        await editor.waitUntilIdle()
        #expect(await library.assetIDs(inAlbum: id) == ["a", "b", "c"])

        // Nothing to add: nothing to undo either, but the album is still the last one used.
        // No group opened by hand here: an empty one would count as something to undo.
        let idle = UndoManager()
        #expect(try await editor.add(["a"], toAlbum: id, undoManager: idle) == 0)
        #expect(!idle.canUndo)
        #expect(editor.lastAlbumID == id)
    }

    @Test func theLastAlbumIsRememberedAcrossLaunches() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try await editor.createAlbum(titled: "First", undoManager: nil)
        let second = try await editor.createAlbum(titled: "Second", undoManager: nil)
        try await editor.add(["a"], toAlbum: first, undoManager: nil)
        try await editor.add(["a"], toAlbum: second, undoManager: nil)
        #expect(editor.lastAlbumID == second)

        let relaunched = PhotosAlbumEditor(library: library, defaults: defaults)
        #expect(relaunched.lastAlbumID == second)
    }

    @Test func removingPhotosIsUndoneByPuttingThemBack() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = try await editor.createAlbum(titled: "Best of", containing: ["a", "b", "c"], undoManager: nil)
        let manager = makeUndoManager()

        let removed = try await step(manager) { try await editor.remove(["b", "z"], fromAlbum: id, undoManager: manager) }
        #expect(removed == 1, "a photo that isn't in the album isn't removed")
        #expect(await library.assetIDs(inAlbum: id) == ["a", "c"])
        #expect(manager.undoActionName == "Remove from Album")

        manager.undo()
        await editor.waitUntilIdle()
        #expect(await library.assetIDs(inAlbum: id) == ["a", "c", "b"], "back, at the end of the album")

        manager.redo()
        await editor.waitUntilIdle()
        #expect(await library.assetIDs(inAlbum: id) == ["a", "c"])
    }

    @Test func aDeletedAlbumComesBackWithItsTitleFolderAndPhotos() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try await editor.createFolder(titled: "Trips", undoManager: nil)
        let id = try await editor.createAlbum(titled: "Iceland", inFolder: folder, containing: ["a", "b"], undoManager: nil)
        let manager = makeUndoManager()

        try await step(manager) { try await editor.deleteAlbum(id: id, undoManager: manager) }
        #expect(await library.albums.isEmpty)
        #expect(manager.undoActionName == "Delete Album")

        manager.undo()
        await editor.waitUntilIdle()
        let restored = try #require(await library.albumID(titled: "Iceland"))
        #expect(await library.albums[restored] == PhotosAlbumContent(title: "Iceland", folderID: folder, assetIDs: ["a", "b"]))

        manager.redo()
        await editor.waitUntilIdle()
        #expect(await library.albums.isEmpty)
    }

    @Test func earlierStepsFollowAnAlbumCreatedAgainByAnUndo() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = try await editor.createAlbum(titled: "Iceland", containing: ["a"], undoManager: nil)
        let manager = makeUndoManager()
        try await step(manager) { try await editor.add(["b"], toAlbum: id, undoManager: manager) }
        try await step(manager) { try await editor.deleteAlbum(id: id, undoManager: manager) }

        // Undo the deletion, then the addition, without waiting in between: the album the second undo
        // acts on doesn't exist yet when it is asked for.
        manager.undo()
        manager.undo()
        await editor.waitUntilIdle()
        let restored = try #require(await library.albumID(titled: "Iceland"))
        #expect(restored != id)
        #expect(await library.assetIDs(inAlbum: restored) == ["a"], "the addition was undone in the album created again")
        #expect(editor.lastAlbumID == restored)

        // Adding to the album by the identifier it had before still reaches it.
        try await editor.add(["c"], toAlbum: id, undoManager: nil)
        #expect(await library.assetIDs(inAlbum: restored) == ["a", "c"])
    }

    @Test func undosAndRedosRunInTheOrderTheyWereAskedFor() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeUndoManager()
        let id = try await step(manager) { try await editor.createAlbum(titled: "Iceland", containing: ["a"], undoManager: manager) }

        manager.undo()
        manager.redo()
        manager.undo()
        manager.redo()
        await editor.waitUntilIdle()
        #expect(await library.journal == ["create \(id)", "delete \(id)", "create album-2", "delete album-2", "create album-3"])
        #expect(await library.assetIDs(inAlbum: "album-3") == ["a"])
    }

    @Test func aNewFolderIsUndoneOnlyWhileItIsEmpty() async throws {
        let (editor, library, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = makeUndoManager()
        let parent = try await editor.createFolder(titled: "Trips", undoManager: nil)
        let folder = try await step(manager) { try await editor.createFolder(titled: "2026", inFolder: parent, undoManager: manager) }
        #expect(await library.folders[folder]?.parentID == parent)
        #expect(manager.undoActionName == "New Folder")

        manager.undo()
        await editor.waitUntilIdle()
        #expect(await library.folders[folder] == nil)

        manager.redo()
        await editor.waitUntilIdle()
        let again = try #require(await library.folders.first { $0.value.title == "2026" }?.key)
        #expect(await library.folders[again]?.parentID == parent)

        // An album made in it since, outside the undo stack (in Photos, say): the folder is kept.
        let album = try await editor.createAlbum(titled: "Iceland", inFolder: folder, undoManager: nil)
        #expect(await library.albums[album]?.folderID == again, "the folder's former identifier still reaches it")
        manager.undo()
        await editor.waitUntilIdle()
        #expect(await library.folders[again] != nil)
        #expect(await library.albums[album] != nil)
    }

    @Test func aFailedChangeIsReportedAndLeavesNothingToUndo() async throws {
        let (editor, _, defaults, suite) = makeEditor()
        defer { defaults.removePersistentDomain(forName: suite) }
        // No group opened by hand here: an empty one would count as something to undo.
        let manager = UndoManager()
        await #expect(throws: PhotosAlbumError.albumUnavailable) {
            try await editor.add(["a"], toAlbum: "gone", undoManager: manager)
        }
        await #expect(throws: PhotosAlbumError.folderUnavailable) {
            try await editor.createAlbum(titled: "Lost", inFolder: "gone", undoManager: manager)
        }
        #expect(!manager.canUndo)
        #expect(editor.lastAlbumID == nil)

        // A change after a failed one still runs: the queue isn't stuck.
        let id = try await editor.createAlbum(titled: "Fine", undoManager: nil)
        #expect(try await editor.add(["a"], toAlbum: id, undoManager: nil) == 1)
    }
}
