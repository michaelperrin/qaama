import Foundation
import Observation
import OSLog

/// Filters saved under a name, with the library they were saved in: an entry of the sidebar that
/// shows that library filtered that way, as a smart album would.
public nonisolated struct FilterPreset: Identifiable, Hashable, Codable, Sendable {
    /// The library a preset filters. The map of every library has none: it lists no photo.
    public enum Library: Hashable, Codable, Sendable {
        /// The whole Apple Photos library.
        case photos
        case photosAlbum(id: String)
        /// A folder on disk, or one of its subdirectories (relative path).
        case folder(id: UUID, path: String?)
    }

    public let id: UUID
    public var name: String
    public var library: Library
    /// What the Filter panel showed when the preset was saved, its switch on.
    public var settings: LibraryFilterSettings

    public init(id: UUID = UUID(), name: String, library: Library, settings: LibraryFilterSettings) {
        self.id = id
        self.name = name
        self.library = library
        self.settings = settings
    }
}

/// The filter presets the user saved, kept in a JSON file of the app's Application Support folder:
/// they are the user's, where the catalog can be rebuilt. Sorted by name, as the sidebar lists them.
///
/// Saving, renaming, updating and deleting a preset are each one step of the window's Edit menu.
@Observable
public final class FilterPresetStore {
    public private(set) var presets: [FilterPreset] = []
    public private(set) var isLoaded = false

    @ObservationIgnored private let fileURL: URL?
    /// The write under way: the next one waits for it, so the file ends as the last change left it.
    @ObservationIgnored private var writing: Task<Void, Never>?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "FilterPresetStore")

    /// `fileURL` is where the presets are kept; nil keeps them in memory (previews, tests).
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FilterPresets.json")
    }

    /// Reads the presets saved before. Calling it again is a no-op.
    public func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        guard let fileURL else { return }
        let read = await Task.detached { () -> Result<[FilterPreset], Error> in
            guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return .success([]) }
            return Result { try JSONDecoder().decode([FilterPreset].self, from: Data(contentsOf: fileURL)) }
        }.value
        switch read {
        case let .success(saved):
            // A preset saved while the file was being read stays.
            presets = Self.sorted(saved.filter { saved in !presets.contains { $0.id == saved.id } } + presets)
            logger.notice("Loaded \(saved.count) filter presets")
        case let .failure(error):
            logger.error("Couldn't read the filter presets: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func preset(id: FilterPreset.ID) -> FilterPreset? {
        presets.first { $0.id == id }
    }

    /// Saves these settings as a preset of a library. An empty name becomes "Untitled Filter"; the
    /// panel's switch is saved on, since a preset that filters nothing shows nothing of its own.
    @discardableResult
    public func add(named name: String, library: FilterPreset.Library, settings: LibraryFilterSettings, undoManager: UndoManager?) -> FilterPreset {
        var settings = settings
        settings.isEnabled = true
        let preset = FilterPreset(name: Self.cleaned(name), library: library, settings: settings)
        replace(with: presets + [preset], actionName: "Save Filter Preset", undoManager: undoManager)
        return preset
    }

    public func rename(_ id: FilterPreset.ID, to name: String, undoManager: UndoManager?) {
        var renamed = presets
        guard let index = renamed.firstIndex(where: { $0.id == id }), renamed[index].name != Self.cleaned(name) else { return }
        renamed[index].name = Self.cleaned(name)
        replace(with: renamed, actionName: "Rename Filter Preset", undoManager: undoManager)
    }

    /// Replaces what a preset filters by, keeping its name and its library. The panel's switch is
    /// saved on, as for a new preset.
    public func update(_ id: FilterPreset.ID, settings: LibraryFilterSettings, undoManager: UndoManager?) {
        var settings = settings
        settings.isEnabled = true
        var updated = presets
        guard let index = updated.firstIndex(where: { $0.id == id }), updated[index].settings != settings else { return }
        updated[index].settings = settings
        replace(with: updated, actionName: "Update Filter Preset", undoManager: undoManager)
    }

    public func delete(_ id: FilterPreset.ID, undoManager: UndoManager?) {
        guard presets.contains(where: { $0.id == id }) else { return }
        replace(with: presets.filter { $0.id != id }, actionName: "Delete Filter Preset", undoManager: undoManager)
    }

    /// Waits for the file to hold the last change, for tests.
    func settled() async {
        await writing?.value
    }

    private static func cleaned(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Filter" : trimmed
    }

    private static func sorted(_ presets: [FilterPreset]) -> [FilterPreset] {
        presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every change goes through here: the list as it was is what undoing it puts back, and that
    /// undo registers its own inverse the same way.
    private func replace(with changed: [FilterPreset], actionName: String, undoManager: UndoManager?) {
        let previous = presets
        presets = Self.sorted(changed)
        write()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.replace(with: previous, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func write() {
        guard let fileURL else { return }
        let presets = presets
        let logger = logger
        writing = Task.detached { [writing] in
            await writing?.value
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(presets).write(to: fileURL, options: .atomic)
            } catch {
                logger.error("Couldn't save the filter presets: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
