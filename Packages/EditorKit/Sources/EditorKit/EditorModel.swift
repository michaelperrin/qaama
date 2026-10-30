import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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
    /// The original file, when the source exposes one: exports copy its metadata.
    private var imageURL: URL?
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

    // MARK: - Layers and masks

    /// The masked layer the sliders edit; nil means the global layer.
    public var selectedLayerID: UUID? {
        didSet { renderPreview() }
    }

    /// Shows the selected layer's mask as a red tint on the canvas.
    public var showsMaskOverlay = false {
        didSet { renderPreview() }
    }

    /// The brush being painted with, when a brush component is active on the selected layer.
    public struct BrushTool: Hashable, Sendable {
        public var componentID: UUID
        /// Radius as a fraction of the reference image's long edge.
        public var radius: Double = 0.03
        public var hardness: Double = 0.5
        public var erases = false

        public init(componentID: UUID, radius: Double = 0.03, hardness: Double = 0.5, erases: Bool = false) {
            self.componentID = componentID
            self.radius = radius
            self.hardness = hardness
            self.erases = erases
        }
    }

    public var brushTool: BrushTool?
    private var currentStroke: BrushMask.Stroke?

    /// True while a masked layer is selected and shown: canvas gestures go to the mask, not to zoom/pan.
    public var isEditingMask: Bool {
        selectedLayer != nil && showsMaskOverlay
    }

    /// Adds a brush component to the selected layer (or a new layer) and starts painting with it.
    public func startBrush(operation: MaskComponent.Operation = .add) {
        let component = MaskComponent(operation: operation, kind: .brush(BrushMask()))
        if let layer = selectedLayer {
            updateMask(layer.id) { $0.components.append(component) }
        } else {
            let layer = AdjustmentLayer(mask: Mask(components: [component]))
            recipe.layers.append(layer)
            selectedLayerID = layer.id
        }
        commitChange()
        brushTool = BrushTool(componentID: component.id)
        showsMaskOverlay = true
    }

    /// Paints with the brush tool; `point` is in the reference frame's unit coordinates.
    public func beginStroke(at point: UnitPoint2D) {
        guard let tool = brushTool else { return }
        currentStroke = BrushMask.Stroke(points: [point], radius: tool.radius, hardness: tool.hardness, opacity: 1, erases: tool.erases)
        appendCurrentStroke(replacingLast: false)
    }

    public func extendStroke(to point: UnitPoint2D) {
        guard currentStroke != nil else { return }
        currentStroke?.points.append(point)
        appendCurrentStroke(replacingLast: true)
    }

    public func endStroke() {
        guard currentStroke != nil else { return }
        currentStroke = nil
        commitChange()
    }

    private func appendCurrentStroke(replacingLast: Bool) {
        guard let tool = brushTool, let stroke = currentStroke, let layer = selectedLayer else { return }
        updateMask(layer.id) { mask in
            guard let index = mask.components.firstIndex(where: { $0.id == tool.componentID }),
                  case var .brush(brush) = mask.components[index].kind else { return }
            if replacingLast, !brush.strokes.isEmpty {
                brush.strokes.removeLast()
            }
            brush.strokes.append(stroke)
            mask.components[index].kind = .brush(brush)
        }
    }

    // MARK: - Reference frame

    /// Maps a point of the displayed image (unit, origin top-left) to the mask reference frame, which
    /// is the straightened image before cropping. While cropping, the displayed image is the frame.
    public func referencePoint(fromDisplayed point: UnitPoint2D) -> UnitPoint2D {
        guard !isCropping, let crop = recipe.geometry?.crop, !crop.isFull else { return point }
        return UnitPoint2D(x: crop.x + point.x * crop.width, y: crop.y + point.y * crop.height)
    }

    public func displayedPoint(fromReference point: UnitPoint2D) -> UnitPoint2D {
        guard !isCropping, let crop = recipe.geometry?.crop, !crop.isFull else { return point }
        return UnitPoint2D(x: (point.x - crop.x) / crop.width, y: (point.y - crop.y) / crop.height)
    }

    /// Precomputed images of model-based mask components (subject, sky…), by component id.
    public private(set) var maskImages: [UUID: CIImage] = [:]
    /// Number of model-based components being computed; the UI shows a spinner while it is non-zero.
    public private(set) var pendingMaskCount = 0
    /// Geometry the current masks were computed in; straightening changes invalidate them.
    private var maskReferenceGeometry: (angle: Double, turns: Int, flipped: Bool)?
    private var maskResolution: Task<Void, Never>?

    private var selectedLayerIndex: Int? {
        guard let selectedLayerID else { return nil }
        return recipe.layers.firstIndex { $0.id == selectedLayerID }
    }

    /// The adjustments the inspector edits: the selected masked layer's, or the global layer's.
    public var adjustments: AdjustmentSet {
        get { selectedLayerIndex.map { recipe.layers[$0].adjustments } ?? recipe.global }
        set {
            if let index = selectedLayerIndex {
                recipe.layers[index].adjustments = newValue
            } else {
                recipe.global = newValue
            }
        }
    }

    /// What the sliders currently edit, for the banner above them.
    public var editingTargetName: String {
        selectedLayerIndex.map { recipe.layers[$0].mask?.displayName ?? "Layer" } ?? "Whole Photo"
    }

    public var selectedLayer: AdjustmentLayer? {
        selectedLayerIndex.map { recipe.layers[$0] }
    }

    /// Adds a layer masked by `kind`, selects it, and records one undo step.
    public func addMaskLayer(_ kind: MaskKind) {
        let layer = AdjustmentLayer(mask: Mask(kind))
        recipe.layers.append(layer)
        selectedLayerID = layer.id
        commitChange()
    }

    public func removeLayer(_ id: UUID) {
        guard let index = recipe.layers.firstIndex(where: { $0.id == id }), index > 0 else { return }
        recipe.layers.remove(at: index)
        if selectedLayerID == id {
            selectedLayerID = nil
            brushTool = nil
        }
        commitChange()
    }

    public func duplicateLayer(_ id: UUID, inverted: Bool) {
        guard let index = recipe.layers.firstIndex(where: { $0.id == id }), index > 0 else { return }
        var copy = recipe.layers[index]
        copy.id = UUID()
        if var mask = copy.mask {
            mask.components = mask.components.map { component in
                var component = component
                component.id = UUID()
                return component
            }
            if inverted {
                mask.isInverted.toggle()
            }
            mask.name = (mask.name ?? mask.displayName) + (inverted ? " (inverted)" : " copy")
            copy.mask = mask
        }
        recipe.layers.insert(copy, at: index + 1)
        selectedLayerID = copy.id
        commitChange()
    }

    public func updateLayer(_ id: UUID, _ change: (inout AdjustmentLayer) -> Void) {
        guard let index = recipe.layers.firstIndex(where: { $0.id == id }), index > 0 else { return }
        change(&recipe.layers[index])
    }

    /// Edits the mask of a layer; call `commitChange()` when the gesture or action is done.
    public func updateMask(_ id: UUID, _ change: (inout Mask) -> Void) {
        updateLayer(id) { layer in
            var mask = layer.mask ?? Mask()
            change(&mask)
            layer.mask = mask
        }
    }

    public func addComponent(_ kind: MaskKind, operation: MaskComponent.Operation, toLayer id: UUID) {
        updateMask(id) { $0.components.append(MaskComponent(operation: operation, kind: kind)) }
        commitChange()
    }

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

    // MARK: - Presets and clipboard

    /// Set when the user asks to save a preset (menu or inspector); the inspector shows the naming prompt.
    public var isNamingPreset = false

    public func requestPresetName() {
        guard isOpen, !recipe.global.isIdentity else { return }
        isNamingPreset = true
    }

    /// Replaces the global adjustments with a preset's (geometry and other layers are untouched).
    public func apply(_ preset: Preset) {
        recipe.global = preset.adjustments
        commitChange()
    }

    public func copyAdjustments(to clipboard: AdjustmentsClipboard = .shared) {
        clipboard.copy(recipe.global)
    }

    /// Pastes the copied adjustments over the global layer, keeping the crop.
    public func pasteAdjustments(from clipboard: AdjustmentsClipboard = .shared) {
        guard let adjustments = clipboard.adjustments else { return }
        recipe.global = adjustments
        commitChange()
    }

    @ObservationIgnored private var histogramTask: Task<Void, Never>?

    /// The edit being made. Sliders write here continuously; call `commitChange()` when a gesture
    /// ends so the undo history gets one entry per gesture, not one per pixel.
    public var recipe = EditRecipe.identity {
        didSet {
            renderPreview()
            resolveModelMasksIfNeeded()
        }
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
                imageURL = url
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
            resolveModelMasksIfNeeded()
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
            RenderPipeline.apply(recipe, to: sourceImage.image, geometry: recipe.geometry?.withoutCrop, masks: maskImages)
        } else {
            RenderPipeline.apply(recipe, to: sourceImage.image, geometry: recipe.geometry, masks: maskImages)
        }
        renderer?.image = showsMaskOverlay ? withMaskOverlay(shown, source: sourceImage.image) : shown
        scheduleHistogram(of: shown)
    }

    /// Computes, in the background, the model-based masks the recipe needs and doesn't have yet, then
    /// re-renders. Straightening or turning the image invalidates them: masks live in that frame.
    private func resolveModelMasksIfNeeded() {
        guard let sourceImage else { return }
        let geometry = recipe.geometry ?? Geometry()
        let frame = (geometry.angle, geometry.quarterTurns, geometry.isFlippedHorizontally)
        if let previous = maskReferenceGeometry, previous != frame {
            maskImages.removeAll()
        }
        maskReferenceGeometry = frame
        let missing = recipe.layers.flatMap { $0.mask?.components ?? [] }.filter { $0.kind.needsModel && maskImages[$0.id] == nil }
        guard !missing.isEmpty, maskResolution == nil else { return }
        let reference = GeometryRenderer.straighten(sourceImage.image, with: geometry)
        pendingMaskCount = missing.count
        maskResolution = Task { [weak self] in
            for component in missing {
                do {
                    if let image = try await ModelMasks.resolve(component.kind, reference: reference) {
                        self?.maskImages[component.id] = image
                    }
                } catch {
                    self?.statusMessage = error.localizedDescription
                }
                self?.pendingMaskCount -= 1
            }
            guard let self else { return }
            maskResolution = nil
            renderPreview()
            // Components added meanwhile.
            resolveModelMasksIfNeeded()
        }
    }

    /// Red tint where the selected layer's mask selects, over the rendered image.
    private func withMaskOverlay(_ image: CIImage, source: CIImage) -> CIImage {
        guard let layer = selectedLayer, let mask = layer.mask else { return image }
        let geometry = isCropping ? recipe.geometry?.withoutCrop : recipe.geometry
        let reference = geometry.map { GeometryRenderer.straighten(source, with: $0) } ?? source
        guard var maskImage = MaskRenderer.render(mask, reference: reference, resolved: maskImages) else { return image }
        if let geometry {
            maskImage = GeometryRenderer.crop(maskImage, with: geometry)
        }
        let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1, alpha: 0.55)).cropped(to: image.extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = red
        blend.backgroundImage = image
        blend.maskImage = maskImage
        return (blend.outputImage ?? image).cropped(to: image.extent)
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
        let masks = maskImages
        return try await Task.detached(priority: .userInitiated) {
            try await ImageExporter.jpegData(for: EditRenderer.render(image: sourceImage.image, recipe: recipe, masks: masks))
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

    /// The open photo with its current edit, saved or not, for the export window.
    public func exportItem() -> ExportItem? {
        guard let sourceImage else { return nil }
        let input = ExportInput(image: sourceImage.image, recipe: recipe, masks: maskImages, baseName: baseName, metadataURL: imageURL)
        return ExportItem(id: assetID) { input }
    }

    // MARK: - Decisions

    public func setRating(_ rating: Int) async {
        guard let asset, asset.rating != rating else { return }
        await change(to: .rating(rating), from: .rating(asset.rating))
    }

    public func setFlag(_ flag: ItemFlag) async {
        guard let asset, asset.flag != flag else { return }
        await change(to: .flag(flag), from: .flag(asset.flag))
    }

    public func setKeywords(_ keywords: [String]) async {
        guard asset != nil, self.keywords != keywords else { return }
        await change(to: .keywords(keywords), from: .keywords(self.keywords))
    }

    /// A rating, flag or keyword change, with the value it replaces so it can be undone.
    enum Decision: Sendable {
        case rating(Int)
        case flag(ItemFlag)
        case keywords([String])

        var actionName: String {
            switch self {
            case .rating: "Rating"
            case .flag: "Flag"
            case .keywords: "Keywords"
            }
        }
    }

    /// Registers the inverse with the undo manager first, synchronously, then applies the decision
    /// through the source.
    private func change(to decision: Decision, from previous: Decision) async {
        registerUndo(restoring: previous, redoing: decision)
        await apply(decision)
    }

    /// Performed by the manager, the undo registers its own inverse (the redo) before the asynchronous
    /// work starts: registering from inside a Task would land outside the undo operation.
    private func registerUndo(restoring previous: Decision, redoing decision: Decision) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerUndo(restoring: decision, redoing: previous)
                Task { @MainActor in await model.apply(previous) }
            }
        }
        undoManager.setActionName(decision.actionName)
    }

    private func apply(_ decision: Decision) async {
        guard let asset else { return }
        switch decision {
        case let .rating(rating):
            await report { try await source.setRating(rating, for: asset) }
        case let .flag(flag):
            await report { try await source.setFlag(flag, for: asset) }
        case let .keywords(keywords):
            self.keywords = keywords
            await report { try await source.setKeywords(keywords, for: asset) }
        }
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
