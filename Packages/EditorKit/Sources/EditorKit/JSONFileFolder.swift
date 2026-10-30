import Foundation
import OSLog

/// A folder of JSON files, one value per file named after the value. Shared by the stores of
/// adjustment presets and export presets: the folder is readable and files can be shared by hand.
nonisolated enum JSONFileFolder {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "JSONFileFolder")

    enum FolderError: Error, LocalizedError {
        case emptyName

        var errorDescription: String? {
            "A preset needs a name."
        }
    }

    /// Every readable `.json` file, sorted by name; unreadable ones are skipped and logged.
    static func load<Value: Decodable>(_: Value.Type, in directory: URL) -> [(name: String, value: Value)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (String, Value)? in
                guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Value.self, from: data) else {
                    logger.error("Skipping unreadable file \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return (url.deletingPathExtension().lastPathComponent, value)
            }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// Saves (or replaces) a value and returns the name used. Slashes and colons can't be in a file
    /// name; they're replaced.
    @discardableResult
    static func save(_ value: some Encodable, named rawName: String, in directory: URL) throws -> String {
        let name = fileSafe(rawName)
        guard !name.isEmpty else { throw FolderError.emptyName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url(for: name, in: directory), options: .atomic)
        logger.notice("Saved \(name, privacy: .public) in \(directory.lastPathComponent, privacy: .public)")
        return name
    }

    static func delete(named name: String, in directory: URL) throws {
        try FileManager.default.removeItem(at: url(for: name, in: directory))
    }

    static func url(for name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    static func fileSafe(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
