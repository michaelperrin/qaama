import Foundation
import Observation
import RenderEngine

/// A saved set of export settings: format, size, frame, watermark, naming and file policies.
public struct ExportPreset: Identifiable, Hashable, Sendable {
    public var id: String {
        name
    }

    public let name: String
    public let settings: ExportSettings
}

/// Export presets as JSON files in the app's Application Support folder, one per preset.
@Observable
public final class ExportPresetStore {
    public private(set) var presets: [ExportPreset] = []

    private let directory: URL

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Export Presets", isDirectory: true)
    }

    public init(directory: URL = ExportPresetStore.defaultDirectory()) {
        self.directory = directory
        reload()
    }

    public func reload() {
        presets = JSONFileFolder.load(ExportSettings.self, in: directory).map { ExportPreset(name: $0.name, settings: $0.value) }
    }

    /// Saves (or replaces) a preset and returns it.
    @discardableResult
    public func save(_ settings: ExportSettings, named rawName: String) throws -> ExportPreset {
        let name: String
        do {
            name = try JSONFileFolder.save(settings, named: rawName, in: directory)
        } catch JSONFileFolder.FolderError.emptyName {
            throw PresetStore.PresetError.emptyName
        }
        reload()
        return ExportPreset(name: name, settings: settings)
    }

    public func delete(_ preset: ExportPreset) throws {
        try JSONFileFolder.delete(named: preset.name, in: directory)
        reload()
    }
}
