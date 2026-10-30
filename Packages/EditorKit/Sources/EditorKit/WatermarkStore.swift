import CoreGraphics
import Foundation
import ImageIO
import Observation
import OSLog
import UniformTypeIdentifiers

/// Pictures used as image watermarks, copied into the app's Application Support folder so the
/// export settings and presets can refer to them by name whatever happens to the original file.
@Observable
public final class WatermarkStore {
    public private(set) var names: [String] = []

    private let directory: URL
    private var images: [String: CGImage] = [:]
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "WatermarkStore")

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Watermarks", isDirectory: true)
    }

    public init(directory: URL = WatermarkStore.defaultDirectory()) {
        self.directory = directory
        reload()
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        names = files.map(\.lastPathComponent).filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Copies a picture in and returns the name to keep in the settings. The original name is kept,
    /// with a counter when it is taken.
    public func importPicture(at url: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let base = url.deletingPathExtension().lastPathComponent
        var name = url.lastPathComponent
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base) \(counter).\(url.pathExtension)"
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
        logger.notice("Imported watermark \(name, privacy: .public)")
        reload()
        return name
    }

    public func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        images[name] = nil
        reload()
    }

    /// The decoded picture, cached; nil when the file is gone or unreadable.
    public func image(named name: String) -> CGImage? {
        if let cached = images[name] {
            return cached
        }
        let url = directory.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }
        images[name] = image
        return image
    }
}
