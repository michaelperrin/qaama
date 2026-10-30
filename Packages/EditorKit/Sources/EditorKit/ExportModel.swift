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

    /// Rendering of the selected photo through the export pipeline, once loaded.
    public private(set) var preview: CGImage?

    /// Resolved once per photo and kept for the window's lifetime.
    private var names: [LibraryAsset.ID: String] = [:]
    private var inputs: [LibraryAsset.ID: ExportInput] = [:]
    /// The edit rendered at preview size and its full pixel size: the frame and watermark are applied
    /// on top of this, so changing them never re-renders the edit.
    private var editedPreviews: [LibraryAsset.ID: (image: CIImage, fullSize: CGSize)] = [:]

    private let defaults: UserDefaults
    public let watermarks: WatermarkStore
    public let presets: ExportPresetStore

    public init(items: [ExportItem], defaults: UserDefaults = .standard, watermarks: WatermarkStore = WatermarkStore(),
                presets: ExportPresetStore = ExportPresetStore())
    {
        self.items = items
        self.defaults = defaults
        self.watermarks = watermarks
        self.presets = presets
        selectedItemID = items.first?.id
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) } ?? ExportSettings()
    }

    public var isBatch: Bool {
        items.count > 1
    }

    public var selectedItem: ExportItem? {
        items.first { $0.id == selectedItemID }
    }

    /// Pixel size of the selected photo after its crop and frame, what the size settings apply to.
    public var sourcePixelSize: CGSize? {
        selectedItemID.flatMap { editedPreviews[$0]?.fullSize }.map { settings.frame.layout(for: $0).canvas }
    }

    public var outputPixelSize: CGSize? {
        sourcePixelSize.map { settings.size.outputSize(for: $0) }
    }

    /// True when the requested size is larger than the photo: allowed, but worth a warning.
    public var isUpscaling: Bool {
        guard let sourcePixelSize, let outputPixelSize else { return false }
        return outputPixelSize.width > sourcePixelSize.width || outputPixelSize.height > sourcePixelSize.height
    }

    /// What the preview depends on; the view reloads it when this changes.
    public struct PreviewKey: Hashable {
        public var itemID: LibraryAsset.ID?
        public var look: ExportSettings.Look
    }

    public var previewKey: PreviewKey {
        PreviewKey(itemID: selectedItemID, look: settings.look)
    }

    /// Suggested file name of the selected photo, without extension (the save panel adds it).
    public var defaultFileName: String {
        selectedItem.flatMap(baseName(for:)) ?? "Photo"
    }

    /// The name a photo will be written under, once its original name is resolved (`name(for:)`).
    public func outputFileName(for item: ExportItem) -> String? {
        baseName(for: item).map { "\($0).\(settings.format.fileExtension)" }
    }

    /// The naming scheme applied to a photo, at its position in the batch.
    private func baseName(for item: ExportItem) -> String? {
        guard let original = names[item.id], let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        return settings.naming.fileName(original: original, index: index)
    }

    public func name(for item: ExportItem) async -> String {
        if let known = names[item.id] {
            return known
        }
        let resolved = await item.name()
        names[item.id] = resolved
        return resolved
    }

    /// Filmstrip image: the library's thumbnail, else the selected photo's preview.
    public func thumbnail(for item: ExportItem, pixelSize: CGSize) async -> CGImage? {
        if let thumbnail = item.thumbnail, let image = await thumbnail(pixelSize) {
            return image
        }
        return item.id == selectedItemID ? preview : nil
    }

    /// Renders the selected photo at preview size: the edit once per photo, then the frame and
    /// watermark on that reduced image each time they change.
    public func loadPreview() async {
        guard let item = selectedItem else { return }
        _ = await name(for: item)
        do {
            let edited: (image: CIImage, fullSize: CGSize)
            if let cached = editedPreviews[item.id] {
                edited = cached
            } else {
                let input = try await input(for: item)
                edited = try await Task.detached(priority: .userInitiated) { () throws -> (CIImage, CGSize) in
                    let full = await EditRenderer.render(image: input.image, recipe: input.recipe, masks: input.masks)
                    // Small photos stay at their size: an enlarged preview would only blur them.
                    let edge = min(Self.previewLongEdge, Int(max(full.extent.width, full.extent.height)))
                    let reduced = ExportRenderer.resize(full, to: .longEdge(edge))
                    let context = CIContext(options: [.cacheIntermediates: false])
                    guard let rendered = context.createCGImage(reduced, from: reduced.extent) else { throw ExportRenderer.ExportError.renderingFailed }
                    return (CIImage(cgImage: rendered), full.extent.size)
                }.value
                editedPreviews[item.id] = edited
            }
            guard item.id == selectedItemID else { return }
            let settings = settings
            let base = edited.image
            let picture = watermarkPicture
            preview = await Task.detached(priority: .userInitiated) {
                let composed = ExportRenderer.compose(base, settings: settings, watermarkPicture: picture)
                return CIContext(options: [.cacheIntermediates: false]).createCGImage(composed, from: composed.extent)
            }.value
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

    /// Writes every photo into `folder` under the naming scheme and the format's extension; existing
    /// files are overwritten or avoided with a numeric suffix as the settings say. Failures are
    /// collected per photo; `cancel()` stops after the current one. Returns the number of files written.
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
        for (index, item) in items.enumerated() where !isCancelled {
            let baseName = await settings.naming.fileName(original: name(for: item), index: index)
            do {
                let data = try await encode(item)
                switch settings.existingFiles {
                case .rename:
                    let name = Self.uniqueFileName(base: baseName, extension: settings.format.fileExtension, taken: &taken)
                    try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
                case .overwrite:
                    try data.write(to: folder.appendingPathComponent("\(baseName).\(settings.format.fileExtension)"), options: .atomic)
                }
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
        let picture = watermarkPicture
        return try await Task.detached(priority: .userInitiated) { try await ExportRenderer.export(input, settings: settings, watermarkPicture: picture) }.value
    }

    /// The picture of an image watermark, decoded by the store, when the settings use one.
    private var watermarkPicture: CIImage? {
        guard settings.watermark.isEnabled, let name = settings.watermark.imageName, let image = watermarks.image(named: name) else { return nil }
        return CIImage(cgImage: image)
    }

    /// Copies a picture into the store and makes it the watermark.
    public func useWatermarkPicture(at url: URL) {
        do {
            let name = try watermarks.importPicture(at: url)
            settings.watermark.kind = .image(name)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Presets

    /// The preset the current settings match exactly, if any.
    public var currentPreset: ExportPreset? {
        presets.presets.first { $0.settings == settings }
    }

    public func apply(_ preset: ExportPreset) {
        settings = preset.settings
    }

    /// Saves the current settings under a name; the error, if any, goes to `errorMessage`.
    public func savePreset(named name: String) {
        do {
            try presets.save(settings, named: name)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteCurrentPreset() {
        guard let preset = currentPreset else { return }
        do {
            try presets.delete(preset)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}
