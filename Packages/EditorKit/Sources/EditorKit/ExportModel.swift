import CoreGraphics
import CoreImage
import EditModel
import Foundation
import LibraryKit
import OSLog
import RenderEngine

/// One photo to export. Everything is resolved on demand, on the main actor, so a batch neither
/// decodes every photo up front nor starts every editing session at once.
public struct ExportItem: Identifiable {
    public let id: LibraryAsset.ID
    /// File name without extension; the export keeps it and only changes the extension.
    public let name: @MainActor () async -> String
    /// A small image for the filmstrip, from the library's caches; nil falls back to the preview.
    public let thumbnail: (@MainActor (CGSize) async -> CGImage?)?
    public let load: @MainActor () async throws -> ExportInput

    public init(id: LibraryAsset.ID, name: @escaping @MainActor () async -> String,
                thumbnail: (@MainActor (CGSize) async -> CGImage?)? = nil,
                load: @escaping @MainActor () async throws -> ExportInput)
    {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
        self.load = load
    }

    /// A photo of the grid with its saved edit, decoded when the export runs.
    public static func make(for asset: LibraryAsset, in source: any LibrarySource) -> ExportItem {
        ExportItem(id: asset.id) {
            let fileName = await source.resourceInfo(for: asset).originalFileName
            return fileName.map { ($0 as NSString).deletingPathExtension } ?? "Photo \(asset.id.prefix(8))"
        } thumbnail: { size in
            await source.thumbnail(for: asset, pixelSize: size)
        } load: {
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
            let loaded = try await Task.detached(priority: .userInitiated) { try SourceImageLoader.load(renderSource) }.value
            return ExportInput(image: loaded.image, recipe: recipe, metadataURL: input.imageURL)
        }
    }
}

/// A photo the batch couldn't write, with the reason to show.
public struct ExportFailure: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let message: String
}

/// State of the export window: the photos to write, the settings (remembered between exports), the
/// photo shown in the preview with its rendering through the export pipeline, the encoding of one
/// photo for the save panel and the writing of a batch into a folder.
@Observable
public final class ExportModel {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "ExportModel")
    nonisolated static let settingsKey = "exportSettings"
    /// Long edge of a preview, enough for the window and cheap to render.
    nonisolated static let previewLongEdge = 1024

    public let items: [ExportItem]
    public var settings: ExportSettings {
        didSet { persistSettings() }
    }

    /// The photo shown large; the view loads its preview when it changes.
    public var selectedItemID: LibraryAsset.ID?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    /// Batch progress: photos handled so far, written or not.
    public private(set) var completedCount = 0
    public private(set) var failures: [ExportFailure] = []
    private var isCancelled = false

    /// Resolved once per photo and kept for the window's lifetime.
    private var names: [LibraryAsset.ID: String] = [:]
    private var inputs: [LibraryAsset.ID: ExportInput] = [:]
    private var previews: [LibraryAsset.ID: CGImage] = [:]
    private var sourceSizes: [LibraryAsset.ID: CGSize] = [:]

    private let defaults: UserDefaults

    public init(items: [ExportItem], defaults: UserDefaults = .standard) {
        self.items = items
        self.defaults = defaults
        selectedItemID = items.first?.id
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
    }

    public var isBatch: Bool {
        items.count > 1
    }

    public var selectedItem: ExportItem? {
        items.first { $0.id == selectedItemID }
    }

    /// Rendering of the selected photo through the export pipeline, once loaded.
    public var preview: CGImage? {
        selectedItemID.flatMap { previews[$0] }
    }

    /// Pixel size of the selected photo after its crop, what the size settings apply to.
    public var sourcePixelSize: CGSize? {
        selectedItemID.flatMap { sourceSizes[$0] }
    }

    public var outputPixelSize: CGSize? {
        sourcePixelSize.map { settings.size.outputSize(for: $0) }
    }

    /// True when the requested size is larger than the photo: allowed, but worth a warning.
    public var isUpscaling: Bool {
        guard let sourcePixelSize, let outputPixelSize else { return false }
        return outputPixelSize.width > sourcePixelSize.width || outputPixelSize.height > sourcePixelSize.height
    }

    /// Suggested file name of the selected photo, without extension (the save panel adds it).
    public var defaultFileName: String {
        selectedItemID.flatMap { names[$0] } ?? "Photo"
    }

    /// The name a photo will be written under, once its name is resolved (`name(for:)`).
    public func outputFileName(for item: ExportItem) -> String? {
        names[item.id].map { "\($0).\(settings.format.fileExtension)" }
    }

    public func name(for item: ExportItem) async -> String {
        if let known = names[item.id] {
            return known
        }
        let resolved = await item.name()
        names[item.id] = resolved
        return resolved
    }

    /// Filmstrip image: the library's thumbnail, else the preview already rendered.
    public func thumbnail(for item: ExportItem, pixelSize: CGSize) async -> CGImage? {
        if let thumbnail = item.thumbnail, let image = await thumbnail(pixelSize) {
            return image
        }
        return previews[item.id]
    }

    /// Renders the selected photo through the export pipeline at preview size, once.
    public func loadPreview() async {
        guard let item = selectedItem else { return }
        _ = await name(for: item)
        guard previews[item.id] == nil else { return }
        do {
            let input = try await input(for: item)
            let (image, size) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGSize) in
                let edited = await EditRenderer.render(image: input.image, recipe: input.recipe, masks: input.masks)
                // Small photos stay at their size: an enlarged preview would only blur them.
                let edge = min(Self.previewLongEdge, Int(max(edited.extent.width, edited.extent.height)))
                let reduced = ExportRenderer.resize(edited, to: .longEdge(edge))
                let context = CIContext(options: [.cacheIntermediates: false])
                return (context.createCGImage(reduced, from: reduced.extent), edited.extent.size)
            }.value
            previews[item.id] = image
            sourceSizes[item.id] = size
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Encodes the selected photo with the current settings, or nil on failure (`errorMessage` says why).
    public func encodeSelected() async -> Data? {
        guard let item = selectedItem else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await encode(item)
            Self.logger.notice("Exported \(self.defaultFileName, privacy: .public) as \(self.settings.format.displayName, privacy: .public), \(data.count) bytes")
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
            let baseName = await name(for: item)
            do {
                let data = try await encode(item)
                let name = Self.uniqueFileName(base: baseName, extension: settings.format.fileExtension, taken: &taken)
                try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
                written += 1
            } catch {
                failures.append(ExportFailure(name: baseName, message: error.localizedDescription))
                Self.logger.error("Export of \(baseName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
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

    private func input(for item: ExportItem) async throws -> ExportInput {
        if let loaded = inputs[item.id] {
            return loaded
        }
        let loaded = try await item.load()
        inputs[item.id] = loaded
        return loaded
    }

    private func encode(_ item: ExportItem) async throws -> Data {
        let input = try await input(for: item)
        let settings = settings
        return try await Task.detached(priority: .userInitiated) { try await ExportRenderer.export(input, settings: settings) }.value
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}
