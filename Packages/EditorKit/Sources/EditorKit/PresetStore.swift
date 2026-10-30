import EditModel
import Foundation
import Observation
import OSLog

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
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "PresetStore")

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
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        presets = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Preset? in
                guard let data = try? Data(contentsOf: url), let adjustments = try? JSONDecoder().decode(AdjustmentSet.self, from: data) else {
                    logger.error("Skipping unreadable preset \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return Preset(name: url.deletingPathExtension().lastPathComponent, adjustments: adjustments)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves (or replaces) a preset. Slashes and colons can't be in a file name; they're replaced.
    public func save(_ adjustments: AdjustmentSet, named rawName: String) throws {
        let name = Self.fileSafe(rawName)
        guard !name.isEmpty else { throw PresetError.emptyName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(adjustments).write(to: url(for: name), options: .atomic)
        logger.notice("Saved preset \(name, privacy: .public)")
        reload()
    }

    public func delete(_ preset: Preset) throws {
        try FileManager.default.removeItem(at: url(for: preset.name))
        reload()
    }

    public enum PresetError: Error, LocalizedError {
        case emptyName

        public var errorDescription: String? {
            "A preset needs a name."
        }
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    static func fileSafe(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
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
