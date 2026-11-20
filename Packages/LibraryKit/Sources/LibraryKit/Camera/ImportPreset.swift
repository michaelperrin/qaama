import Foundation
import Observation
import OSLog

/// What the import sheet is set to, apart from what is asked each time (deleting from the device):
/// where the photos go, how they are filed, and what comes with them.
public nonisolated struct ImportSettings: Codable, Hashable, Sendable {
    /// The value of `destination` for the Photos library; otherwise a folder's identifier.
    public static let photosDestination = "photos"

    public var destination: String
    /// The album of the Photos library the photos are added to, if any.
    public var albumID: String?
    public var layout: ImportLayout
    public var keywords: [String]
    public var includesVideos: Bool
    /// The folder of the second copies, as a security-scoped bookmark; nil for none.
    public var secondCopyBookmark: Data?
    public var ejects: Bool

    public init(destination: String, albumID: String? = nil, layout: ImportLayout = .byDay, keywords: [String] = [],
                includesVideos: Bool = true, secondCopyBookmark: Data? = nil, ejects: Bool = false)
    {
        self.destination = destination
        self.albumID = albumID
        self.layout = layout
        self.keywords = keywords
        self.includesVideos = includesVideos
        self.secondCopyBookmark = secondCopyBookmark
        self.ejects = ejects
    }
}

/// Import settings saved under a name, to set the sheet in one choice: "Holidays to Photos",
/// "Work, with a second copy".
public nonisolated struct ImportPreset: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var settings: ImportSettings

    public var id: String {
        name
    }
}

/// The import presets, in a JSON file of Application Support in the app (user data, as the filter
/// presets are), in memory in tests.
@Observable
public final class ImportPresetStore {
    /// By name, as the Finder sorts names.
    public private(set) var presets: [ImportPreset] = []

    private let fileURL: URL?
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "ImportPresetStore")

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            presets = try Self.sorted(JSONDecoder().decode([ImportPreset].self, from: data))
        } catch {
            logger.error("Couldn't read the import presets: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ImportPresets.json")
    }

    /// The preset these settings are, if they were saved as they are.
    public func preset(matching settings: ImportSettings) -> ImportPreset? {
        presets.first { $0.settings == settings }
    }

    /// Saves settings under a name, in place of the preset of that name if there is one. An empty
    /// name becomes "Untitled Preset".
    @discardableResult
    public func save(_ settings: ImportSettings, named name: String) -> ImportPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = ImportPreset(name: trimmed.isEmpty ? "Untitled Preset" : trimmed, settings: settings)
        presets = Self.sorted(presets.filter { $0.name != preset.name } + [preset])
        write()
        return preset
    }

    public func delete(_ preset: ImportPreset) {
        presets.removeAll { $0.name == preset.name }
        write()
    }

    private static func sorted(_ presets: [ImportPreset]) -> [ImportPreset] {
        presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A few presets at most: written at once, so a preset saved right before quitting is kept.
    private func write() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(presets).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Couldn't save the import presets: \(error.localizedDescription, privacy: .public)")
        }
    }
}
