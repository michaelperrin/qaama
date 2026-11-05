import CoreGraphics
import Foundation
import LibraryKit
import Observation
import OSLog
import RenderEngine

/// One stay in the editor: the photo being edited, and the canvas it is drawn on.
///
/// Stepping to another photo replaces the photo's model and keeps everything else: the Metal
/// canvas and its Core Image context here, the views built on top of them in the app. Rebuilding
/// those for each photo cost about 100 ms, three times what opening the photo itself takes.
@Observable
public final class EditorSession {
    public let source: any LibrarySource
    /// The photo being edited. Replaced by `show(_:)`: views should read it from here each time
    /// rather than hold on to it.
    public private(set) var model: EditorModel
    /// The window's undo manager, handed to each photo's model in turn.
    @ObservationIgnored public var undoManager: UndoManager? {
        didSet { model.undoManager = undoManager }
    }

    @ObservationIgnored private let renderer: CanvasRenderer?
    @ObservationIgnored private var shownAt = ContinuousClock.now
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "EditorSession")

    public init(assetID: LibraryAsset.ID, source: any LibrarySource, renderer: CanvasRenderer? = CanvasRenderer()) {
        self.source = source
        self.renderer = renderer
        model = EditorModel(assetID: assetID, source: source, renderer: renderer)
    }

    /// The photo `offset` places away in the library's current order; nil at either end.
    public func neighbor(offset: Int) -> LibraryAsset.ID? {
        source.neighbor(of: model.assetID, offset: offset)
    }

    /// Moves the session to another photo. The previous photo's model is closed, unsaved edits
    /// included: the caller decides what to do with them first. The canvas keeps showing the
    /// previous photo until the new one is decoded, so stepping through photos doesn't flash.
    public func show(_ assetID: LibraryAsset.ID) {
        guard assetID != model.assetID else { return }
        model.close()
        renderer?.zoom = 1
        renderer?.panOffset = .zero
        shownAt = .now
        let next = EditorModel(assetID: assetID, source: source, renderer: renderer)
        next.undoManager = undoManager
        model = next
    }

    /// Opens the current photo, then reports how long it took to reach the screen since `show(_:)`
    /// or the start of the session. Returns once the photo is drawn, or right away if the session
    /// moved on meanwhile.
    public func openCurrentPhoto() async {
        let model = model
        await model.open()
        let opened = ContinuousClock.now
        guard !model.isClosed, let renderer, let preview = renderer.image else { return }
        // The preview is set, not yet drawn: decoding happens in the first render, and a RAW takes
        // a few hundred milliseconds. Wait for the frame showing this very image.
        let deadline = opened + .seconds(3)
        while renderer.presentedImage !== preview, renderer.image === preview, !model.isClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard !model.isClosed, renderer.presentedImage === preview else { return }
        let size = model.sourceImage?.pixelSize ?? .zero
        let kind = model.sourceImage?.isRAW == true ? "RAW" : "image"
        let format = Duration.UnitsFormatStyle.units(allowed: [.milliseconds])
        logger.notice("Showed \(kind, privacy: .public) \(Int(size.width))x\(Int(size.height)) \((ContinuousClock.now - self.shownAt).formatted(format), privacy: .public) after it was asked for: opened in \((opened - self.shownAt).formatted(format), privacy: .public), first frame \((ContinuousClock.now - opened).formatted(format), privacy: .public) (\(model.assetID, privacy: .public))")
    }

    /// Ends the session. Call when the editor goes away.
    public func close() {
        model.close()
    }
}
