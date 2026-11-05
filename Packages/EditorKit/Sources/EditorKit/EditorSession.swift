import CoreGraphics
import Foundation
import LibraryKit
import Observation
import OSLog
import RenderEngine

/// One stay in the editor: the photo being edited, and the canvas it is drawn on.
///
/// Stepping to another photo replaces the photo's model and keeps everything else: the Metal
/// canvas and its Core Image context here, the views built on top of them in the app.
///
/// The photo on screen comes first, the rest follows once the user stays on it (`settleDelay`):
/// its full resolution if it appeared as a draft, the inspector (`settledModel`), then the two
/// photos next to it, read and decoded ahead so that stepping to them is immediate. Stepping on
/// before that cancels it all, so going quickly through photos only ever pays for drafts.
@Observable
public final class EditorSession {
    public let source: any LibrarySource
    /// The photo being edited. Replaced by `show(_:)`: views should read it from here each time
    /// rather than hold on to it.
    public private(set) var model: EditorModel
    /// The photo the user last stayed on: nil until the first one settles, behind `model` while
    /// photos go by. What is expensive to refresh, like the inspector, shows this one.
    public private(set) var settledModel: EditorModel?
    /// The window's undo manager, handed to each photo's model in turn.
    @ObservationIgnored public var undoManager: UndoManager? {
        didSet { model.undoManager = undoManager }
    }

    @ObservationIgnored private let renderer: CanvasRenderer?
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private var shownAt = ContinuousClock.now
    /// What was read ahead for the current photo and its neighbors, in flight or done. The session
    /// owns what the source holds for each of them and releases it in `release(_:)`.
    @ObservationIgnored private var preparations: [LibraryAsset.ID: Task<PreparedPhoto, Error>] = [:]
    /// Photos read ahead whose draft is already decoded into pixels of its own.
    @ObservationIgnored private var decoded: Set<LibraryAsset.ID> = []
    /// Which way the user last stepped: +1 toward the next photo, -1 toward the previous one. The
    /// photo further that way is the one most likely to be asked for, so it is read ahead first.
    @ObservationIgnored private var direction = 1
    private let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "EditorSession")

    public init(assetID: LibraryAsset.ID, source: any LibrarySource, renderer: CanvasRenderer? = CanvasRenderer(),
                settleDelay: Duration = .milliseconds(200))
    {
        self.source = source
        self.renderer = renderer
        self.settleDelay = settleDelay
        let preparation = Self.preparation(of: assetID, in: source)
        preparations[assetID] = preparation
        model = EditorModel(assetID: assetID, source: source, renderer: renderer, preparation: preparation)
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
        let previous = model.assetID
        direction = source.neighbor(of: previous, offset: -1) == assetID ? -1 : 1
        model.close()
        // The photo just left may have been edited or saved since it was read: what the session
        // holds for it is stale. It is read again if it ends up next to a photo the user stays on.
        release(previous)
        renderer?.zoom = 1
        renderer?.panOffset = .zero
        shownAt = .now
        let preparation = preparations[assetID] ?? Self.preparation(of: assetID, in: source)
        preparations[assetID] = preparation
        let next = EditorModel(assetID: assetID, source: source, renderer: renderer, preparation: preparation)
        next.undoManager = undoManager
        model = next
    }

    /// Opens the current photo and stays with it: once it has been on screen for `settleDelay`,
    /// shows its full resolution, settles it, and prepares its neighbors. Call from a task tied to
    /// the photo and cancelled when the session moves on.
    public func followCurrentPhoto() async {
        let model = model
        await model.open()
        let opened = ContinuousClock.now
        guard !model.isClosed else { return }
        if await waitUntilPresented(model) {
            let size = model.sourceImage?.pixelSize ?? .zero
            let kind = model.sourceImage?.isRAW == true ? (model.showsDraft ? "RAW draft" : "RAW") : "image"
            let format = Duration.UnitsFormatStyle.units(allowed: [.milliseconds])
            logger.notice("Showed \(kind, privacy: .public) \(Int(size.width))x\(Int(size.height)) \((ContinuousClock.now - self.shownAt).formatted(format), privacy: .public) after it was asked for: opened in \((opened - self.shownAt).formatted(format), privacy: .public), first frame \((ContinuousClock.now - opened).formatted(format), privacy: .public) (\(model.assetID, privacy: .public))")
        }
        try? await Task.sleep(for: settleDelay)
        guard !Task.isCancelled, !model.isClosed else { return }

        let settled = ContinuousClock.now
        let hadDraft = model.showsDraft
        model.showFullResolution()
        settledModel = model
        if hadDraft, await waitUntilPresented(model) {
            logger.notice("Full resolution \((ContinuousClock.now - settled).formatted(.units(allowed: [.milliseconds])), privacy: .public) after settling (\(model.assetID, privacy: .public))")
        }
        await prepareNeighbors(of: model)
    }

    /// Ends the session. Call when the editor goes away.
    public func close() {
        model.close()
        for id in Array(preparations.keys) {
            release(id)
        }
    }

    // MARK: - Reading ahead

    private static func preparation(of id: LibraryAsset.ID, in source: any LibrarySource) -> Task<PreparedPhoto, Error> {
        Task {
            guard let asset = source.asset(id: id) else { throw LibrarySourceError.assetUnavailable }
            return try await PreparedPhoto.prepare(asset, in: source)
        }
    }

    /// Reads the photos on both sides ahead, the one in the direction of travel first, and decodes
    /// their drafts so the canvas can draw them at once. Photos that are no longer next to the
    /// current one are let go.
    private func prepareNeighbors(of model: EditorModel) async {
        let neighbors = [direction, -direction].compactMap { source.neighbor(of: model.assetID, offset: $0) }
        let wanted = Set(neighbors + [model.assetID])
        for id in Array(preparations.keys) where !wanted.contains(id) {
            release(id)
        }
        for id in neighbors {
            guard !Task.isCancelled, !model.isClosed else { return }
            let start = ContinuousClock.now
            let preparation = preparations[id] ?? Self.preparation(of: id, in: source)
            preparations[id] = preparation
            guard let photo = try? await preparation.value else {
                // Failed and released by itself: forget it, so that showing the photo tries again.
                if preparations[id] == preparation {
                    preparations[id] = nil
                }
                continue
            }
            guard !Task.isCancelled, !model.isClosed, !decoded.contains(id), let draft = photo.sourceImage.draftPixels,
                  let pixels = await renderer?.rasterized(draft) else { continue }
            // Unless the photo was let go or asked for again meanwhile, hand out the decoded draft
            // from now on. The editing input is the same one: releasing it works as before.
            guard preparations[id] == preparation else { continue }
            let ready = PreparedPhoto(keywords: photo.keywords, input: photo.input, sourceImage: photo.sourceImage.withDraftPixels(pixels), metadata: photo.metadata)
            preparations[id] = Task { ready }
            decoded.insert(id)
            logger.notice("Read \(id, privacy: .public) ahead in \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])), privacy: .public), draft decoded")
        }
    }

    /// Forgets what was read for a photo and, once that reading has ended, has the source release
    /// what it holds for it, unless the photo was asked for again in the meantime.
    private func release(_ id: LibraryAsset.ID) {
        decoded.remove(id)
        guard let preparation = preparations.removeValue(forKey: id) else { return }
        let source = source
        Task { [weak self] in
            // A failed preparation has nothing left to release.
            guard await (try? preparation.value) != nil else { return }
            if let self, self.preparations[id] != nil {
                return
            }
            if let asset = source.asset(id: id) {
                source.endEditing(asset)
            }
        }
    }

    /// Waits until the canvas has drawn the model's current preview: decoding happens in the first
    /// render, and a RAW takes a few hundred milliseconds. False if the session moved on, the
    /// preview changed meanwhile, or there is no canvas.
    private func waitUntilPresented(_ model: EditorModel) async -> Bool {
        guard let renderer, let preview = renderer.image else { return false }
        let deadline = ContinuousClock.now + .seconds(3)
        while renderer.presentedImage !== preview, renderer.image === preview, !model.isClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return !model.isClosed && renderer.presentedImage === preview
    }
}
