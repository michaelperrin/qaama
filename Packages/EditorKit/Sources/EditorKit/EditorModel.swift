import CoreGraphics
import CoreImage
import EditModel
import Foundation
import ImageIOKit
import LibraryKit
import Observation
import OSLog
import RenderEngine

/// Everything the editor does, without the views: opens the original through the library source,
/// keeps the recipe and its undo history, renders the preview into the canvas, saves and exports.
///
/// One instance per edited photo. Views read its state and call its actions.
@Observable
public final class EditorModel {
    public let assetID: LibraryAsset.ID
    public let source: any LibrarySource
    /// The Metal canvas the preview is rendered into; nil when Metal is unavailable or in tests.
    public let renderer: CanvasRenderer?

    public private(set) var sourceImage: SourceImage?
    /// File name without extension, for export suggestions.
    public private(set) var baseName = "Photo"
    public private(set) var savedRecipe = EditRecipe.identity
    public private(set) var isBusy = false
    public private(set) var statusMessage: String?
    public private(set) var keywords: [String] = []
    public private(set) var undoStack: [EditRecipe] = []
    public private(set) var redoStack: [EditRecipe] = []
    /// Header of the original (EXIF), read when the editor opens; nil when the source gives no file.
    public private(set) var metadata: ImageMetadata?
    /// Histogram of the current edit, refreshed shortly after each change.
    public private(set) var histogram: Histogram?
    /// While true the canvas shows the original instead of the edit (press-and-hold comparison).
    public var isShowingOriginal = false {
        didSet { renderPreview() }
    }

    /// While true the canvas shows the straightened image without its crop, under the crop frame.
    public private(set) var isCropping = false

    /// The recipe's geometry, or a blank one to start from; writing an identity stores nil.
    public var geometry: Geometry {
        get { recipe.geometry ?? Geometry() }
        set { recipe.geometry = newValue.isIdentity && !isCropping ? nil : newValue }
    }

    public func beginCropping() {
        guard !isCropping else { return }
        isCropping = true
        renderer?.zoom = 1
        renderer?.panOffset = .zero
        renderPreview()
    }

    public func endCropping() {
        guard isCropping else { return }
        isCropping = false
        if recipe.geometry?.isIdentity == true {
            recipe.geometry = nil
        }
        commitChange()
        renderPreview()
    }

    public func toggleCropping() {
        isCropping ? endCropping() : beginCropping()
    }

    /// Turns the image by a quarter clockwise (+1) or counterclockwise (-1), keeping the crop.
    public func rotate(quarterTurns: Int) {
        geometry.quarterTurns = ((geometry.quarterTurns + quarterTurns) % 4 + 4) % 4
        commitChange()
    }

    public func flipHorizontally() {
        geometry.isFlippedHorizontally.toggle()
        commitChange()
    }

    public func resetGeometry() {
        recipe.geometry = isCropping ? Geometry() : nil
        commitChange()
    }

    @ObservationIgnored private var histogramTask: Task<Void, Never>?

    /// The edit being made. Sliders write here continuously; call `commitChange()` when a gesture
    /// ends so the undo history gets one entry per gesture, not one per pixel.
    public var recipe = EditRecipe.identity {
        didSet { renderPreview() }
    }

    /// The window's undo manager, so the Edit menu and its shortcuts drive the same history.
    /// Set by the view; registrations go both ways (menu → model, model → menu).
    @ObservationIgnored public var undoManager: UndoManager? {
        didSet { oldValue?.removeAllActions(withTarget: self) }
    }

    private var checkpoint = EditRecipe.identity
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "EditorModel")

    public init(assetID: LibraryAsset.ID, source: any LibrarySource, renderer: CanvasRenderer? = CanvasRenderer()) {
        self.assetID = assetID
        self.source = source
        self.renderer = renderer
    }

    // MARK: - Derived state

    /// Live copy of the asset, so ratings and flags follow library changes.
    public var asset: LibraryAsset? {
        source.asset(id: assetID)
    }

    public var isOpen: Bool {
        sourceImage != nil
    }

    public var hasUnsavedChanges: Bool {
        recipe != savedRecipe
    }

    public var canSave: Bool {
        isOpen && !isBusy && hasUnsavedChanges
    }

    public var canExport: Bool {
        isOpen && !isBusy
    }

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    // MARK: - Lifecycle

    /// Loads keywords, the saved recipe and the original, then renders the first preview.
    public func open() async {
        guard let asset else {
            statusMessage = LibrarySourceError.assetUnavailable.localizedDescription
            return
        }
        do {
            keywords = await source.keywords(for: asset)
            let input = try await source.editingInput(for: asset)
            if let url = input.imageURL {
                baseName = url.deletingPathExtension().lastPathComponent
            }
            if let data = input.recipeData {
                if let saved = try? EditRecipe(jsonData: data) {
                    recipe = saved
                    savedRecipe = saved
                } else {
                    // No backward compatibility while the format is young: start from the original.
                    statusMessage = "The saved edit uses an unsupported format; starting from the original."
                }
            }
            checkpoint = recipe
            let renderSource: RenderSource
            if let url = input.imageURL {
                renderSource = .file(url)
            } else if let image = input.image {
                renderSource = .image(image)
            } else {
                throw LibrarySourceError.editingFailed("no image data")
            }
            sourceImage = try await Task.detached(priority: .userInitiated) { try SourceImageLoader.load(renderSource) }.value
            renderPreview()
            if let url = input.imageURL {
                metadata = await Task.detached { try? ImageMetadataReader.read(url) }.value
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Releases what the source held for the edit. Call when the editor goes away.
    public func close() {
        undoManager?.removeAllActions(withTarget: self)
        if let asset {
            source.endEditing(asset)
        }
    }

    // MARK: - Recipe and history

    /// Records the current recipe as one undoable step, if it changed since the last checkpoint.
    public func commitChange() {
        guard recipe != checkpoint else { return }
        undoStack.append(checkpoint)
        redoStack.removeAll()
        checkpoint = recipe
        registerUndo()
    }

    public func reset() {
        recipe = .identity
        commitChange()
    }

    /// Steps back one committed change. When the window has an undo manager, the Edit menu calls
    /// this through it; the inspector's button goes through the manager too so both stay in sync.
    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
        checkpoint = previous
        // Registered while undoing, the manager files this as the matching redo.
        registerUndo(isRedo: true)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        checkpoint = next
        registerUndo()
    }

    private func registerUndo(isRedo: Bool = false) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            if isRedo {
                model.redo()
            } else {
                model.undo()
            }
        }
        undoManager.setActionName("Adjustment")
    }

    private func renderPreview() {
        guard let sourceImage else { return }
        let shown: CIImage = if isShowingOriginal {
            sourceImage.image
        } else if isCropping {
            // The crop tool frames the straightened image: show it whole, the frame does the cropping.
            RenderPipeline.apply(recipe, to: sourceImage.image, geometry: recipe.geometry?.withoutCrop)
        } else {
            RenderPipeline.apply(recipe, to: sourceImage.image)
        }
        renderer?.image = shown
        scheduleHistogram(of: shown)
    }

    /// Recomputes the histogram once the sliders settle: one computation per burst of changes.
    private func scheduleHistogram(of image: CIImage) {
        histogramTask?.cancel()
        histogramTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let computed = await Task.detached(priority: .utility) { HistogramComputer.compute(image) }.value
            guard !Task.isCancelled else { return }
            self?.histogram = computed
        }
    }

    // MARK: - Output

    /// Full-size JPEG of the current edit, rendered off the main actor.
    public func renderJPEG() async throws -> Data {
        guard let sourceImage else { throw LibrarySourceError.assetUnavailable }
        let recipe = recipe
        return try await Task.detached(priority: .userInitiated) {
            try ImageExporter.jpegData(for: RenderPipeline.apply(recipe, to: sourceImage.image))
        }.value
    }

    /// Stores the edit through the source (sidecar or Photos). A neutral recipe reverts the photo.
    public func save() async {
        guard let asset, canSave else { return }
        await busy {
            let output = try await EditingOutput(recipeData: recipe.jsonData(), renderedJPEG: renderJPEG(), isReset: recipe.isIdentity)
            try await source.saveEdit(output, for: asset)
            savedRecipe = recipe
            logger.notice("Saved edit of \(self.assetID, privacy: .public)")
        }
    }

    /// JPEG bytes to hand to a file exporter, or nil on failure (the status message says why).
    public func exportJPEG() async -> Data? {
        var data: Data?
        await busy { data = try await renderJPEG() }
        return data
    }

    // MARK: - Decisions

    public func setRating(_ rating: Int) async {
        guard let asset else { return }
        await report { try await source.setRating(rating, for: asset) }
    }

    public func setFlag(_ flag: ItemFlag) async {
        guard let asset else { return }
        await report { try await source.setFlag(flag, for: asset) }
    }

    public func setKeywords(_ keywords: [String]) async {
        guard let asset else { return }
        self.keywords = keywords
        await report { try await source.setKeywords(keywords, for: asset) }
    }

    // MARK: - Helpers

    private func busy(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        await report(work)
    }

    /// Runs an action and shows its error, if any, clearing the previous one on success.
    private func report(_ work: () async throws -> Void) async {
        do {
            try await work()
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
