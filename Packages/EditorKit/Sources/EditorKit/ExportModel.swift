import CoreGraphics
import CoreImage
import EditModel
import Foundation
import LibraryKit
import OSLog
import RenderEngine

/// One photo to export. Its pixels and recipe are loaded on demand, so a batch doesn't decode
/// everything up front.
public struct ExportItem: Identifiable, Sendable {
    public let id: LibraryAsset.ID
    /// File name without extension; the export keeps it and only changes the extension.
    public let baseName: String
    public let load: @Sendable () async throws -> ExportInput

    public init(id: LibraryAsset.ID, baseName: String, load: @escaping @Sendable () async throws -> ExportInput) {
        self.id = id
        self.baseName = baseName
        self.load = load
    }
}

/// State of the export window: the photos to write, the settings (remembered between exports), a
/// preview of the first photo rendered through the export pipeline, and the encoding itself.
@Observable
public final class ExportModel {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "ExportModel")
    nonisolated static let settingsKey = "exportSettings"
    /// Long edge of the preview, enough for the window and cheap to render.
    nonisolated static let previewLongEdge = 1024

    public let items: [ExportItem]
    public var settings: ExportSettings {
        didSet { persistSettings() }
    }

    public private(set) var preview: CGImage?
    /// Pixel size of the first photo after its crop, what the size settings apply to.
    public private(set) var sourcePixelSize: CGSize?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    private let defaults: UserDefaults

    public init(items: [ExportItem], defaults: UserDefaults = .standard) {
        self.items = items
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
    }

    public var outputPixelSize: CGSize? {
        sourcePixelSize.map { settings.size.outputSize(for: $0) }
    }

    /// True when the requested size is larger than the photo: allowed, but worth a warning.
    public var isUpscaling: Bool {
        guard let sourcePixelSize, let outputPixelSize else { return false }
        return outputPixelSize.width > sourcePixelSize.width || outputPixelSize.height > sourcePixelSize.height
    }

    /// Suggested file name of the first photo, without extension (the save panel adds it).
    public var defaultFileName: String {
        items.first?.baseName ?? "Photo"
    }

    /// Renders the first photo through the export pipeline at preview size.
    public func loadPreview() async {
        guard let item = items.first else { return }
        do {
            let (image, size) = try await Task.detached(priority: .userInitiated) { () throws -> (CGImage?, CGSize) in
                let input = try await item.load()
                let edited = await EditRenderer.render(image: input.image, recipe: input.recipe, masks: input.masks)
                // Small photos stay at their size: an enlarged preview would only blur them.
                let edge = min(Self.previewLongEdge, Int(max(edited.extent.width, edited.extent.height)))
                let reduced = ExportRenderer.resize(edited, to: .longEdge(edge))
                let context = CIContext(options: [.cacheIntermediates: false])
                return (context.createCGImage(reduced, from: reduced.extent), edited.extent.size)
            }.value
            preview = image
            sourcePixelSize = size
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Encodes the first photo with the current settings, or nil on failure (`errorMessage` says why).
    public func encodeFirst() async -> Data? {
        guard let item = items.first else { return nil }
        isBusy = true
        defer { isBusy = false }
        let settings = settings
        do {
            let clock = ContinuousClock()
            let start = clock.now
            let data = try await Task.detached(priority: .userInitiated) {
                try await ExportRenderer.export(item.load(), settings: settings)
            }.value
            Self.logger.notice("Exported \(item.baseName, privacy: .public) as \(settings.format.displayName, privacy: .public) (\(data.count) bytes) in \(clock.now - start, privacy: .public)")
            errorMessage = nil
            return data
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}
