import EditModel
import Foundation
import Observation

/// A saved set of adjustments the user can apply to other photos.
public struct Preset: Identifiable, Hashable, Sendable {
    public var id: String {
        name
    }

    public let name: String
    public let adjustments: AdjustmentSet
}

/// Presets as JSON files, one per preset, in the app's Application Support folder. The file name is
/// the preset name, so the folder is readable and files can be shared by hand.
@Observable
public final class PresetStore {
    public private(set) var presets: [Preset] = []

    private let directory: URL

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Presets", isDirectory: true)
    }

    public init(directory: URL = PresetStore.defaultDirectory()) {
        self.directory = directory
        reload()
    }

    /// Reads every `.json` file of the folder; unreadable ones are skipped and logged.
    public func reload() {
        presets = JSONFileFolder.load(AdjustmentSet.self, in: directory).map { Preset(name: $0.name, adjustments: $0.value) }
    }

    /// Saves (or replaces) a preset. Slashes and colons can't be in a file name; they're replaced.
    public func save(_ adjustments: AdjustmentSet, named rawName: String) throws {
        do {
            try JSONFileFolder.save(adjustments, named: rawName, in: directory)
        } catch JSONFileFolder.FolderError.emptyName {
            throw PresetError.emptyName
        }
        reload()
    }

    public func delete(_ preset: Preset) throws {
        try JSONFileFolder.delete(named: preset.name, in: directory)
        reload()
    }

    public enum PresetError: Error, LocalizedError {
        case emptyName

        public var errorDescription: String? {
            "A preset needs a name."
        }
    }
}

/// Session-wide clipboard for adjustments, shared by every editor.
@Observable
public final class AdjustmentsClipboard {
    public static let shared = AdjustmentsClipboard()
    public private(set) var adjustments: AdjustmentSet?

    public func copy(_ adjustments: AdjustmentSet) {
        self.adjustments = adjustments
    }
}
