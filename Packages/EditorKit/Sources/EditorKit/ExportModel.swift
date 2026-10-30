import CoreGraphics
import CoreImage
import EditModel
import Foundation
import LibraryKit
import OSLog
import RenderEngine

/// One photo to export. Its pixels, recipe and name are loaded on demand, on the main actor, so a
/// batch neither decodes everything up front nor starts every editing session at once.
public struct ExportItem: Identifiable {
    public let id: LibraryAsset.ID
    public let load: @MainActor () async throws -> ExportInput

    public init(id: LibraryAsset.ID, load: @escaping @MainActor () async throws -> ExportInput) {
        self.id = id
        self.load = load
    }

    /// A photo of the grid with its saved edit, decoded when the export runs.
    public static func make(for asset: LibraryAsset, in source: any LibrarySource) -> ExportItem {
        ExportItem(id: asset.id) {
            let input = try await source.editingInput(for: asset)
            // The pixels are in hand (a URL or a decoded image): the session can end before rendering.
            source.endEditing(asset)
            let recipe = input.recipeData.flatMap { try? EditRecipe(jsonData: $0) } ?? EditRecipe()
            let renderSource: RenderSource
            if let url = input.imageURL {
                renderSource = .file(url)
            } else if let image = input.image {
                renderSource = .image(image)
            } else {
                throw LibrarySourceError.editingFailed("no image data")
            }
            let fileName = await source.resourceInfo(for: asset).originalFileName ?? input.imageURL?.lastPathComponent
            let baseName = fileName.map { ($0 as NSString).deletingPathExtension } ?? "Photo \(asset.id.prefix(8))"
            let loaded = try await Task.detached(priority: .userInitiated) { try SourceImageLoader.load(renderSource) }.value
            return ExportInput(image: loaded.image, recipe: recipe, baseName: baseName, metadataURL: input.imageURL)
        }
    }
}

/// A photo the batch couldn't write, with the reason to show.
public struct ExportFailure: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let message: String
}

/// State of the export window: the photos to write, the settings (remembered between exports), a
/// preview of the first photo rendered through the export pipeline, the encoding of one photo for
/// the save panel and the writing of a batch into a folder.
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
    /// Name of the first photo, known once its preview is loaded.
    public private(set) var firstBaseName: String?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    /// Batch progress: photos handled so far, written or not.
    public private(set) var completedCount = 0
    public private(set) var failures: [ExportFailure] = []
    private var isCancelled = false

    private let defaults: UserDefaults

    public init(items: [ExportItem], defaults: UserDefaults = .standard) {
        self.items = items
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
    }

    public var isBatch: Bool {
        items.count > 1
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
        firstBaseName ?? "Photo"
    }

    /// Renders the first photo through the export pipeline at preview size.
    public func loadPreview() async {
        guard let item = items.first else { return }
        do {
            let input = try await item.load()
            firstBaseName = input.baseName
            let (image, size) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGSize) in
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
        do {
            let (data, name) = try await encode(item)
            Self.logger.notice("Exported \(name, privacy: .public) as \(self.settings.format.displayName, privacy: .public), \(data.count) bytes")
            errorMessage = nil
            return data
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Writes every photo into `folder`, named after the original with the format's extension and a
    /// numeric suffix when the name is taken. Failures are collected per photo; `cancel()` stops after
    /// the current one. Returns the number of files written.
    @discardableResult
    public func exportAll(to folder: URL) async -> Int {
        isBusy = true
        isCancelled = false
        completedCount = 0
        failures = []
        defer { isBusy = false }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.map { $0.lowercased() } ?? [])
        var written = 0
        let clock = ContinuousClock()
        let start = clock.now
        for item in items where !isCancelled {
            do {
                let (data, baseName) = try await encode(item)
                let name = Self.uniqueFileName(base: baseName, extension: settings.format.fileExtension, taken: &taken)
                try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
                written += 1
            } catch {
                failures.append(ExportFailure(name: item.id, message: error.localizedDescription))
                Self.logger.error("Export of \(item.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            completedCount += 1
        }
        Self.logger.notice("Exported \(written) of \(self.items.count) photos as \(self.settings.format.displayName, privacy: .public) in \(clock.now - start, privacy: .public)")
        return written
    }

    public func cancel() {
        isCancelled = true
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`… when taken; comparisons ignore case like the file
    /// system does. The chosen name is added to `taken`.
    nonisolated static func uniqueFileName(base: String, extension fileExtension: String, taken: inout Set<String>) -> String {
        var candidate = "\(base).\(fileExtension)"
        var index = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(index).\(fileExtension)"
            index += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private func encode(_ item: ExportItem) async throws -> (Data, String) {
        let input = try await item.load()
        let settings = settings
        let data = try await Task.detached(priority: .userInitiated) { try await ExportRenderer.export(input, settings: settings) }.value
        return (data, input.baseName)
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}
