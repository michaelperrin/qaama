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
/// One instance per edited photo, so a photo never inherits state from the previous one. The canvas
/// can outlive it: an `EditorSession` hands the same renderer to each photo's model in turn, and
/// `close()` cuts a model off from it for good.
@Observable
public final class EditorModel {
    public let assetID: LibraryAsset.ID
    public let source: any LibrarySource
    /// The Metal canvas the preview is rendered into; nil when Metal is unavailable, in tests, and
    /// once the model is closed.
    public private(set) var renderer: CanvasRenderer?
    /// True once `close()` was called: the canvas may now belong to another photo, so nothing this
    /// model still has in flight (opening, mask computation) may draw.
    public private(set) var isClosed = false

    public private(set) var sourceImage: SourceImage?
    /// True while the canvas shows the source's draft instead of its full resolution: a RAW appears
    /// with its quick draft decode, and gets the full one once the user stays on it.
    public private(set) var showsDraft = false
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
    /// What the Edit menu calls each step of the two stacks.
    private var undoNames: [String] = []
    private var redoNames: [String] = []
    /// Header of the original (EXIF), read when the editor opens; nil when the source gives no file.
    private var header: ImageMetadata?
    /// The read of that header, for the export, which may be asked for before it has finished.
    @ObservationIgnored private var headerTask: Task<ImageMetadata?, Never>?
    /// What the Info tab shows: the header, with the capture date as the library holds it now, since
    /// the user may have corrected it.
    public var metadata: ImageMetadata? {
        guard var shown = header else { return nil }
        if let asset, let date = source.captureDate(for: asset) {
            shown.captureDate = date
        }
        return shown
    }

    /// Histogram of the current edit, refreshed shortly after each change.
    public private(set) var histogram: Histogram?
    /// The hues of the photo as the color mixer of the edited layer receives it, before the mixer
    /// and what follows it (black and white, grain, vignette): what its ranges can act on.
    public private(set) var hueHistogram: HueHistogram?
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
    /// The stroke being painted. It stays out of `recipe` until the mouse goes up: every view that
    /// reads the recipe would otherwise be re-evaluated per point, which costs far more than the
    /// render itself. The preview merges it in through `previewRecipe`.
    @ObservationIgnored private var currentStroke: BrushMask.Stroke?
    /// Where the time of the stroke being painted goes; reported once the stroke ends.
    private var strokeTiming: (start: ContinuousClock.Instant, points: Int, model: Duration)?

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
        renderer?.resetDrawStats()
        strokeTiming = (.now, 1, .zero)
        renderPreview()
    }

    public func extendStroke(to point: UnitPoint2D) {
        guard currentStroke != nil else { return }
        let start = ContinuousClock.now
        currentStroke?.points.append(point)
        renderPreview()
        strokeTiming?.points += 1
        strokeTiming?.model += .now - start
    }

    /// Writes the stroke into the recipe, as one undoable change.
    public func endStroke() {
        guard let stroke = currentStroke else { return }
        currentStroke = nil
        recipe = recipe(adding: stroke)
        commitChange()
        if let timing = strokeTiming, let stats = renderer?.drawStats {
            let total = ContinuousClock.now - timing.start
            let ms = { (d: Duration) in Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
            let points = max(timing.points, 1), frames = max(stats.frames, 1)
            logger.notice("Brush stroke: \(timing.points) points in \(ms(total), format: .fixed(precision: 0)) ms (\(ms(total) / Double(points), format: .fixed(precision: 1)) ms/point), model+graph \(ms(timing.model) / Double(points), format: .fixed(precision: 1)) ms/point, canvas \(stats.frames) frames, encode \(ms(stats.encode) / Double(frames), format: .fixed(precision: 1)) ms, completion \(ms(stats.completion) / Double(frames), format: .fixed(precision: 1)) ms")
        }
        strokeTiming = nil
    }

    /// The recipe with `stroke` appended to the brush component being painted.
    private func recipe(adding stroke: BrushMask.Stroke) -> EditRecipe {
        guard let tool = brushTool, let layerIndex = selectedLayerIndex, layerIndex > 0, var mask = recipe.layers[layerIndex].mask,
              let index = mask.components.firstIndex(where: { $0.id == tool.componentID }),
              case var .brush(brush) = mask.components[index].kind else { return recipe }
        brush.strokes.append(stroke)
        mask.components[index].kind = .brush(brush)
        var recipe = recipe
        recipe.layers[layerIndex].mask = mask
        return recipe
    }

    /// What the canvas shows: the recipe, plus the stroke being painted and the LUT being tried.
    private var previewRecipe: EditRecipe {
        var shown = currentStroke.map { recipe(adding: $0) } ?? recipe
        if let lutPreview, shown.layers.indices.contains(selectedLayerIndex ?? 0) {
            let index = selectedLayerIndex ?? 0
            shown.layers[index].adjustments.lut = lutPreview.applied(to: shown.layers[index].adjustments.lut)
        }
        return shown
    }

    // MARK: - Retouch

    /// The retouch brush, while the retouch tool is on: dragging on the canvas paints what to remove.
    public struct RetouchTool: Hashable, Sendable {
        /// Radius as a fraction of the original's long edge.
        public var radius: Double

        public init(radius: Double = 0.02) {
            self.radius = min(max(radius, Retouch.radiusRange.lowerBound), Retouch.radiusRange.upperBound)
        }
    }

    public private(set) var retouchTool: RetouchTool?

    public var isRetouching: Bool {
        retouchTool != nil
    }

    /// Changes the brush size, kept within what the tool offers.
    public func setRetouchRadius(_ radius: Double) {
        guard isRetouching else { return }
        retouchTool = RetouchTool(radius: radius)
    }

    /// The stroke being painted, for the canvas to draw. It enters the recipe when the mouse goes up.
    public private(set) var retouchStroke: Retouch?
    /// What each retouch puts in place of what was painted out (`RetouchRenderer`), by retouch id.
    public private(set) var retouchFills: [UUID: CIImage] = [:]
    /// The retouches those fills were computed for, in order: each fill was computed on top of the
    /// ones before it, so it is only good for a list that starts the same way.
    private var filledRetouches: [Retouch] = []
    private var retouchResolution: Task<Void, Never>?
    /// The noise reduction of the original the fills were computed on: a fill copies the grain
    /// around it, so it is only good for the original decoded that way.
    @ObservationIgnored private var retouchDenoise: Denoise?
    /// The wait for the noise reduction to settle before the fills are computed again.
    @ObservationIgnored private var retouchRefresh: Task<Void, Never>?
    /// How long the noise reduction must stay as it is before the fills follow it.
    static let retouchRefreshDelay: Duration = .milliseconds(300)

    /// The fills that go with the current recipe, for a render that reuses them: none while they
    /// still belong to another noise reduction, and only the ones already computed again while
    /// they follow a new one. The render computes the rest itself.
    private var currentFills: [UUID: CIImage] {
        guard retouchDenoise == recipe.sourceDenoise else { return [:] }
        let filled = Set(filledRetouches.map(\.id))
        return retouchFills.filter { filled.contains($0.key) }
    }

    /// Retouches whose fill is still being computed: the canvas shows them as painted meanwhile.
    public var pendingRetouches: [Retouch] {
        recipe.retouches.filter { retouchFills[$0.id] == nil }
    }

    /// Turns the retouch tool on, leaving the crop tool and mask painting.
    public func beginRetouching(radius: Double = 0.02) {
        guard !isRetouching, isOpen else { return }
        endCropping()
        brushTool = nil
        showsMaskOverlay = false
        retouchTool = RetouchTool(radius: radius)
    }

    public func endRetouching() {
        guard isRetouching else { return }
        retouchTool = nil
        retouchStroke = nil
    }

    /// Paints with the retouch brush; points are in the original's unit coordinates
    /// (`sourcePoint(fromDisplayed:)`).
    public func beginRetouchStroke(at point: UnitPoint2D) {
        guard let tool = retouchTool else { return }
        retouchStroke = Retouch(points: [point], radius: tool.radius)
    }

    public func extendRetouchStroke(to point: UnitPoint2D) {
        guard retouchStroke != nil, retouchStroke?.points.last != point else { return }
        retouchStroke?.points.append(point)
    }

    /// Writes the stroke into the recipe, as one undoable change; its fill follows in the background.
    public func endRetouchStroke() {
        guard let stroke = retouchStroke else { return }
        retouchStroke = nil
        recipe.retouches.append(stroke)
        commitChange(named: "Retouch")
    }

    /// Brings back everything that was painted out, as one undoable change.
    public func removeRetouches() {
        guard !recipe.retouches.isEmpty else { return }
        recipe.retouches.removeAll()
        commitChange(named: "Remove Retouches")
    }

    /// Maps a point of the displayed image (unit, origin top-left) to the original, where retouches
    /// are defined, undoing the crop, the straightening, the turns and the flip.
    public func sourcePoint(fromDisplayed point: UnitPoint2D) -> UnitPoint2D {
        let reference = referencePoint(fromDisplayed: point)
        guard let geometry = recipe.geometry, let size = sourceImage?.pixelSize else { return reference }
        return geometry.sourcePoint(fromReference: reference, width: size.width, height: size.height)
    }

    public func displayedPoint(fromSource point: UnitPoint2D) -> UnitPoint2D {
        guard let geometry = recipe.geometry, let size = sourceImage?.pixelSize else { return displayedPoint(fromReference: point) }
        return displayedPoint(fromReference: geometry.referencePoint(fromSource: point, width: size.width, height: size.height))
    }

    /// Computes, in the background and one at a time, the fills the recipe's retouches don't have
    /// yet, then re-renders. Fills computed for a list this one has diverged from are dropped from
    /// the point where they differ; those of retouches merely undone are kept for the redo.
    private func resolveRetouchesIfNeeded() {
        let retouches = recipe.retouches
        guard !retouches.isEmpty || !filledRetouches.isEmpty, !isClosed, let sourceImage else { return }
        let denoise = recipe.sourceDenoise
        if denoise != retouchDenoise {
            if filledRetouches.isEmpty, retouchResolution == nil {
                retouchDenoise = denoise
            } else {
                // The fills on screen copy the grain of an original decoded otherwise. They stay
                // there while the amounts move, and are computed again once the amounts settle.
                refreshRetouchesOnceDenoiseSettles()
                return
            }
        }
        let shared = zip(retouches, filledRetouches).prefix { $0 == $1 }.count
        if shared < min(retouches.count, filledRetouches.count) {
            for stale in filledRetouches[shared...] {
                retouchFills[stale.id] = nil
            }
            filledRetouches.removeSubrange(shared...)
        }
        guard retouchResolution == nil, filledRetouches.count < retouches.count else { return }
        let next = retouches[filledRetouches.count]
        let earlier = filledRetouches
        let base = RetouchRenderer.apply(earlier, fills: retouchFills, to: denoisedImage(of: sourceImage, for: recipe))
        // The canvas's context has the original decoded already: a RAW isn't decoded again.
        let context = renderer?.renderingContext
        retouchResolution = Task { [weak self] in
            let fill = await Task.detached(priority: .userInitiated) { RetouchRenderer.fill(next, in: base, context: context) }.value
            guard let self, !isClosed else { return }
            retouchResolution = nil
            // The list may have changed while this ran: the fill is kept only if it still follows
            // the same retouches, on the original decoded the same way.
            if filledRetouches == earlier, retouchDenoise == denoise, recipe.retouches.starts(with: earlier + [next]) {
                if fill == nil {
                    statusMessage = "There is nothing around that area to fill it with."
                }
                retouchFills[next.id] = fill ?? CIImage.empty()
                filledRetouches.append(next)
                renderPreview()
            }
            resolveRetouchesIfNeeded()
        }
    }

    /// Computes every fill again, in order, once the recipe's noise reduction has stayed the same
    /// for `retouchRefreshDelay`. The old fills stay on screen until each is replaced, so nothing
    /// that was painted out comes back meanwhile.
    private func refreshRetouchesOnceDenoiseSettles() {
        retouchRefresh?.cancel()
        retouchRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.retouchRefreshDelay)
            guard !Task.isCancelled, let self, !isClosed else { return }
            retouchRefresh = nil
            guard retouchDenoise != recipe.sourceDenoise else { return }
            retouchDenoise = recipe.sourceDenoise
            filledRetouches.removeAll()
            resolveRetouchesIfNeeded()
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
        commitChange(named: inverted ? "Duplicate and Invert Mask" : "Duplicate Mask")
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
        endRetouching()
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
        commitChange(named: "Reset Crop & Straighten")
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
        commitChange(named: "Apply Preset")
    }

    public func copyAdjustments(to clipboard: AdjustmentsClipboard = .shared) {
        clipboard.copy(recipe.global)
    }

    /// Pastes the copied adjustments over the global layer, keeping the crop.
    public func pasteAdjustments(from clipboard: AdjustmentsClipboard = .shared) {
        guard let adjustments = clipboard.adjustments else { return }
        recipe.global = adjustments
        commitChange(named: "Paste Adjustments")
    }

    // MARK: - LUT

    /// What the LUT menu offers for the layer being edited: no table, or one of the library's.
    public enum LUTChoice: Hashable, Sendable {
        case none
        case table(String)

        /// The layer's LUT setting once this is chosen: a table is switched on and keeps the
        /// intensity already set; no table keeps the switch and the intensity for the next one.
        func applied(to current: LUT?) -> LUT? {
            switch self {
            case .none:
                guard var lut = current else { return nil }
                lut.name = nil
                return lut
            case let .table(name):
                var lut = current ?? LUT()
                lut.name = name
                lut.isEnabled = true
                return lut
            }
        }
    }

    /// The choice the pointer is on in the LUT menu: the canvas shows it in place of the layer's
    /// own, and the recipe is left alone. Like the stroke being painted, it stays out of what the
    /// views observe: trying a look redraws the canvas, not the inspector.
    @ObservationIgnored private var lutPreview: LUTChoice?

    /// Shows a choice of the LUT menu on the canvas without making it; nil goes back to the recipe.
    public func previewLUT(_ choice: LUTChoice?) {
        guard choice != lutPreview else { return }
        lutPreview = choice
        renderPreview()
    }

    /// Gives the layer being edited a table, or none, as one undoable change.
    public func chooseLUT(_ choice: LUTChoice) {
        let wasPreviewing = lutPreview != nil
        lutPreview = nil
        let chosen = choice.applied(to: adjustments.lut)
        if chosen != adjustments.lut {
            adjustments.lut = chosen
            commitChange(named: choice == .none ? "Remove LUT" : "Apply LUT")
        } else if wasPreviewing {
            // Nothing changed in the recipe, so nothing redrew the canvas without the preview.
            renderPreview()
        }
    }

    /// The original as last decoded for a recipe's noise reduction; see `denoisedImage(of:for:)`.
    @ObservationIgnored private var denoised: (denoise: Denoise, image: CIImage)?
    @ObservationIgnored private var histogramTask: Task<Void, Never>?
    @ObservationIgnored private var hueHistogramTask: Task<Void, Never>?
    /// What the current hue histogram was computed from (or is being computed from), so moving the
    /// mixer's own sliders, which leaves it unchanged, costs nothing.
    @ObservationIgnored private var hueHistogramSource: HueHistogramSource?

    /// Everything the image entering the color mixer depends on.
    private struct HueHistogramSource: Equatable {
        let recipe: EditRecipe
        /// Masks and retouch fills arrive after the recipe that asks for them.
        let maskIDs: Set<UUID>
        let fillIDs: Set<UUID>
    }

    /// The edit being made. Sliders write here continuously; call `commitChange()` when a gesture
    /// ends so the undo history gets one entry per gesture, not one per pixel.
    public var recipe = EditRecipe.identity {
        didSet {
            renderPreview()
            resolveModelMasksIfNeeded()
            resolveRetouchesIfNeeded()
        }
    }

    /// The window's undo manager, so the Edit menu and its shortcuts drive the same history.
    /// Set by the view; registrations go both ways (menu → model, model → menu).
    @ObservationIgnored public var undoManager: UndoManager? {
        didSet { oldValue?.removeAllActions(withTarget: self) }
    }

    private var checkpoint = EditRecipe.identity
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "EditorModel")

    /// What `open()` reads, when it was started ahead of time: an `EditorSession` prepares the
    /// photos next to the current one. The session then owns what the source holds for the edit,
    /// and releases it; without a preparation the model asks the source itself and releases on close.
    private let preparation: Task<PreparedPhoto, Error>?

    /// Where the tables named by the recipe are read from, for the canvas.
    private let luts: LUTLibrary

    public init(assetID: LibraryAsset.ID, source: any LibrarySource, renderer: CanvasRenderer? = CanvasRenderer(),
                preparation: Task<PreparedPhoto, Error>? = nil, luts: LUTLibrary = .shared)
    {
        self.assetID = assetID
        self.source = source
        self.renderer = renderer
        self.preparation = preparation
        self.luts = luts
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
        guard !isClosed else { return }
        guard let asset else {
            statusMessage = LibrarySourceError.assetUnavailable.localizedDescription
            return
        }
        let start = ContinuousClock.now
        do {
            let photo = if let preparation {
                try await preparation.value
            } else {
                try await PreparedPhoto.prepare(asset, in: source)
            }
            guard !isClosed else {
                // Closed while the source was preparing the edit: release what it just handed over.
                if preparation == nil {
                    source.endEditing(asset)
                }
                return
            }
            keywords = photo.keywords
            if let url = photo.input.imageURL {
                baseName = url.deletingPathExtension().lastPathComponent
                imageURL = url
            }
            if let data = photo.input.recipeData {
                if let saved = try? EditRecipe(jsonData: data) {
                    recipe = saved
                    savedRecipe = saved
                } else {
                    // No backward compatibility while the format is young: start from the original.
                    statusMessage = "The saved edit uses an unsupported format; starting from the original."
                }
            }
            checkpoint = recipe
            sourceImage = photo.sourceImage
            showsDraft = photo.sourceImage.draft != nil
            renderPreview()
            logger.notice("Opened \(self.assetID, privacy: .public) in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            resolveModelMasksIfNeeded()
            resolveRetouchesIfNeeded()
            headerTask = photo.metadata
            header = await photo.metadata?.value
        } catch {
            statusMessage = error.localizedDescription
            // The canvas may still show the previous photo of the session: don't leave it there
            // under this photo's name.
            renderer?.image = nil
        }
    }

    /// Releases what the source held for the edit and lets go of the canvas. Call when the editor
    /// goes away or moves to another photo; a closed model stays closed.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        renderer = nil
        maskResolution?.cancel()
        retouchResolution?.cancel()
        retouchRefresh?.cancel()
        histogramTask?.cancel()
        hueHistogramTask?.cancel()
        undoManager?.removeAllActions(withTarget: self)
        if preparation == nil, let asset {
            source.endEditing(asset)
        }
    }

    /// Replaces the draft on the canvas with the full resolution. The session calls it once the
    /// user stays on the photo: the full decode of a RAW keeps the GPU busy for a few hundred
    /// milliseconds, which stepping through photos must not queue up behind.
    public func showFullResolution() {
        guard showsDraft, !isClosed else { return }
        showsDraft = false
        renderPreview()
    }

    // MARK: - Recipe and history

    /// Records the current recipe as one undoable step, if it changed since the last checkpoint,
    /// named in the Edit menu after what changed (`EditActionName`).
    public func commitChange() {
        guard recipe != checkpoint else { return }
        commitChange(named: EditActionName.describing(from: checkpoint, to: recipe))
    }

    /// Same, under the name the Edit menu shows after Undo and Redo.
    public func commitChange(named actionName: String) {
        guard recipe != checkpoint else { return }
        undoStack.append(checkpoint)
        undoNames.append(actionName)
        redoStack.removeAll()
        redoNames.removeAll()
        checkpoint = recipe
        registerUndo(named: actionName)
    }

    public func reset() {
        recipe = .identity
        commitChange(named: "Revert to Original")
    }

    /// Steps back one committed change. When the window has an undo manager, the Edit menu calls
    /// this through it; the inspector's button goes through the manager too so both stay in sync.
    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        let name = undoNames.popLast() ?? EditActionName.several
        redoStack.append(recipe)
        redoNames.append(name)
        recipe = previous
        checkpoint = previous
        // Registered while undoing, the manager files this as the matching redo.
        registerUndo(named: name, isRedo: true)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        let name = redoNames.popLast() ?? EditActionName.several
        undoStack.append(recipe)
        undoNames.append(name)
        recipe = next
        checkpoint = next
        registerUndo(named: name)
    }

    private func registerUndo(named actionName: String, isRedo: Bool = false) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            if isRedo {
                model.redo()
            } else {
                model.undo()
            }
        }
        undoManager.setActionName(actionName)
    }

    /// The original decoded with the recipe's noise reduction. The same image is handed out for as
    /// long as the amounts stay the same, so Core Image keeps it decoded while other sliders move;
    /// while they change, each position is a new image, which takes the place of the one before.
    private func denoisedImage(of sourceImage: SourceImage, for recipe: EditRecipe) -> CIImage {
        guard let denoise = recipe.sourceDenoise else { return sourceImage.image }
        if let denoised, denoised.denoise == denoise {
            return denoised.image
        }
        let image = sourceImage.image(denoise: denoise)
        denoised = (denoise, image)
        return image
    }

    private func renderPreview() {
        guard !isClosed, let sourceImage else { return }
        let recipe = previewRecipe
        // The draft has the full image's extent, so everything downstream treats it the same. It is
        // shown as decoded by default: the recipe's noise reduction comes with the full resolution.
        let original = showsDraft ? sourceImage.draft ?? sourceImage.image : sourceImage.image
        let source = showsDraft ? original : denoisedImage(of: sourceImage, for: recipe)
        let shown: CIImage = if isShowingOriginal {
            original
        } else if isCropping {
            // The crop tool frames the straightened image: show it whole, the frame does the cropping.
            RenderPipeline.apply(recipe, to: source, geometry: recipe.geometry?.withoutCrop, masks: maskImages, fills: retouchFills, luts: luts)
        } else {
            RenderPipeline.apply(recipe, to: source, geometry: recipe.geometry, masks: maskImages, fills: retouchFills, luts: luts)
        }
        renderer?.image = showsMaskOverlay ? withMaskOverlay(shown, of: recipe, source: source) : shown
        scheduleHistogram(of: shown)
        scheduleHueHistogram(of: recipe, source: source)
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
    private func withMaskOverlay(_ image: CIImage, of recipe: EditRecipe, source: CIImage) -> CIImage {
        guard let index = selectedLayerIndex, let mask = recipe.layers[index].mask else { return image }
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

    /// Recomputes the hue histogram when what enters the color mixer changed, once the sliders
    /// settle. The draft and the full resolution hold the same hues: either will do.
    private func scheduleHueHistogram(of recipe: EditRecipe, source: CIImage) {
        let upstream = RenderPipeline.colorMixerUpstream(of: recipe, layerIndex: selectedLayerIndex ?? 0)
        let key = HueHistogramSource(recipe: upstream, maskIDs: Set(maskImages.keys), fillIDs: Set(retouchFills.keys))
        guard key != hueHistogramSource else { return }
        hueHistogramSource = key
        let image = RenderPipeline.apply(upstream, to: source, geometry: upstream.geometry, masks: maskImages, fills: retouchFills)
        hueHistogramTask?.cancel()
        hueHistogramTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let computed = await Task.detached(priority: .utility) { HueHistogramComputer.compute(image) }.value
            guard !Task.isCancelled else { return }
            self?.hueHistogram = computed
        }
    }

    // MARK: - Output

    /// Full-size JPEG of the current edit, rendered off the main actor.
    public func renderJPEG() async throws -> Data {
        guard let sourceImage else { throw LibrarySourceError.assetUnavailable }
        let recipe = recipe
        let masks = maskImages, fills = currentFills
        return try await Task.detached(priority: .userInitiated) {
            try await ImageExporter.jpegData(for: EditRenderer.render(source: sourceImage, recipe: recipe, masks: masks, fills: fills))
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
        let input = ExportInput(source: sourceImage, recipe: recipe, masks: maskImages, fills: currentFills, metadataURL: imageURL)
        let name = baseName
        let headerTask = headerTask
        let source = source
        let asset = asset
        return ExportItem(id: assetID, name: { name }, load: {
            // A capture date or a location corrected in the library replaces the original's in the exported file.
            var input = input
            let header = await headerTask?.value
            input.captureDate = ExportItem.captureDateToWrite(library: asset.flatMap { source.captureDate(for: $0) }, file: header?.captureDate)
            input.location = asset.flatMap { LocationCorrection.between(file: header?.location, location: source.location(for: $0)) }
            return input
        })
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
    typealias Decision = LibraryDecision

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
        if case let .keywords(keywords) = decision {
            self.keywords = keywords
        }
        await report { try await source.apply(decision, to: asset) }
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
