import Foundation
import Observation
import OSLog

/// A photo of the Apple Photos library deleted in Qaama, and when.
public nonisolated struct TrashedPhoto: Hashable, Codable, Sendable {
    /// The photo's local identifier in the Photos library.
    public var id: String
    public var deletedAt: Date

    public init(id: String, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// The photos of the Apple Photos library deleted in Qaama: its own Recently Deleted.
///
/// PhotoKit can list Photos' Recently Deleted album no more than it can take a photo back out of
/// it, so deleting in Qaama doesn't delete in Photos: the photo is noted here, every listing of
/// the library leaves it out (`PhotosLibrarySource`), and it stays in the Photos library, where
/// Photos and the other devices still show it, until it is deleted from Recently Deleted. That is
/// what makes deleting a step Edit › Undo reverts, and restoring another.
///
/// Kept in a JSON file of the app's Application Support folder: user data, which nothing in the
/// Photos library says, unlike the catalog.
@Observable
public final class PhotosTrash {
    /// The deleted photos, in the order they were deleted.
    public private(set) var photos: [TrashedPhoto] = []
    /// Their identifiers, for the listings to leave out.
    public private(set) var ids: Set<String> = []
    /// Bumped with every change of `ids`: what a listing was made with tells whether it is current.
    public private(set) var version = 0

    @ObservationIgnored private let fileURL: URL?
    /// The reading of the file, shared by everyone who waits for it.
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The write under way: the next one waits for it, so the file ends as the last change left it.
    @ObservationIgnored private var writing: Task<Void, Never>?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PhotosTrash")

    /// `fileURL` is where the list is kept; nil keeps it in memory (previews, tests).
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PhotosTrash.json")
    }

    /// Reads the list saved before. Every caller waits for the same reading: a library listed
    /// before it ended would show the deleted photos for a moment.
    public func load() async {
        if loading == nil {
            loading = Task { await read() }
        }
        await loading?.value
    }

    /// Notes photos as deleted, as one step of the Edit menu. Those already noted are left as they are.
    public func trash(_ ids: [String], at date: Date = .now, undoManager: UndoManager?) {
        apply(.add(ids.map { TrashedPhoto(id: $0, deletedAt: date) }), named: ids.count == 1 ? "Delete Photo" : "Delete Photos",
              undoManager: undoManager)
    }

    /// Puts deleted photos back in the library, as one step of the Edit menu.
    public func restore(_ ids: [String], undoManager: UndoManager?) {
        apply(.remove(ids), named: ids.count == 1 ? "Restore Photo" : "Restore Photos", undoManager: undoManager)
    }

    /// Drops photos that are no longer in the Photos library: deleted from there for good, here or
    /// in Photos. Not a step of the Edit menu: there is nothing left to bring back.
    public func forget(_ ids: some Sequence<String>) {
        apply(.remove(Array(ids)), named: "", undoManager: nil)
    }

    /// Waits for the file to hold the last change, for tests.
    func settled() async {
        await writing?.value
    }

    /// One change of the list, which the opposite change reverts.
    private nonisolated enum Change: Sendable {
        case add([TrashedPhoto])
        case remove([String])
    }

    /// Every change goes through here. Its undo is the opposite change of what really changed (a
    /// photo deleted for good since isn't brought back as an entry), and registers its own inverse
    /// the same way, under the same name: the Edit menu then reads Undo and Redo of one action.
    private func apply(_ change: Change, named name: String, undoManager: UndoManager?) {
        let inverse: Change
        switch change {
        case let .add(added):
            var seen = ids
            let new = added.filter { seen.insert($0.id).inserted }
            guard !new.isEmpty else { return }
            set(photos + new)
            inverse = .remove(new.map(\.id))
        case let .remove(removed):
            let removed = Set(removed)
            let gone = photos.filter { removed.contains($0.id) }
            guard !gone.isEmpty else { return }
            set(photos.filter { !removed.contains($0.id) })
            inverse = .add(gone)
        }
        write()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { trash in
            MainActor.assumeIsolated {
                trash.apply(inverse, named: name, undoManager: undoManager)
            }
        }
        undoManager.setActionName(name)
    }

    private func set(_ changed: [TrashedPhoto]) {
        photos = changed
        ids = Set(changed.map(\.id))
        version += 1
    }

    private func read() async {
        guard let fileURL else { return }
        let read = await Task.detached { () -> Result<[TrashedPhoto], Error> in
            guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .success([]) }
            return Result { try JSONDecoder().decode([TrashedPhoto].self, from: Data(contentsOf: fileURL)) }
        }.value
        switch read {
        case let .success(saved):
            // A photo deleted while the file was being read stays.
            let kept = saved.filter { !ids.contains($0.id) }
            if !kept.isEmpty {
                set(kept + photos)
            }
            logger.notice("Loaded \(saved.count) deleted photos")
        case let .failure(error):
            logger.error("Couldn't read the deleted photos: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write() {
        guard let fileURL else { return }
        let photos = photos
        let logger = logger
        writing = Task.detached { [writing] in
            await writing?.value
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(photos).write(to: fileURL, options: .atomic)
            } catch {
                logger.error("Couldn't save the deleted photos: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
