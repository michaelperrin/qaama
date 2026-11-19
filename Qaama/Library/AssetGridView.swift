import AppKit
import EditorKit
import LibraryKit
import SwiftUI

/// Thumbnail grid shared by every library source, with multiple selection: click selects, ⌘-click
/// toggles, ⇧-click extends from the last click, double-click opens the editor. The arrow keys move
/// the selection, ⇧ with them extends it.
///
/// Each cell is an `AssetGridCell` with inputs that only change when the photo or the selection does,
/// and its actions on one object that stays the same (`actions`): the grid is rebuilt on every change
/// of the library (every second or two while Photos is analyzing or syncing), and a context menu that
/// is open must not notice. See `AssetGridCell`.
///
/// When the source knows the months of its photos (`LibrarySource.timeline`, photos sorted by capture
/// date), the grid is cut into one section per month, each under its name. The headers scroll with
/// the photos: a first version pinned the header of the month on screen under the toolbar, as a bar,
/// which sat badly there (Michaël, 2026-11-10); the dates on screen are told in the window's subtitle
/// instead. Cells keep their row as identifier whatever their section, and sections are identified by
/// their month: a photo added elsewhere or the dates arriving late leave the thumbnails on screen as
/// they are. Measured with a probe (docs/PLAN.md): among 74,000 cells in 125 sections, a jump to a far
/// row lands in 25 ms, to the point.
struct AssetGridView: View {
    let source: any LibrarySource
    @Binding var selection: Set<LibraryAsset.ID>
    let onOpen: (LibraryAsset.ID) -> Void
    /// Opens the Adjust Date & Time dialog for these photos; nil leaves the command out.
    var onAdjustDate: (([LibraryAsset]) -> Void)?
    /// Runs a Location item of the context menu for these photos; nil leaves the items out.
    var onLocation: ((LocationCommand, [LibraryAsset.ID]) -> Void)?
    /// Filing in albums: its items in the context menu, and thumbnails that can be dragged to an
    /// album of the sidebar. Nil for libraries without albums.
    var albums: AlbumsAction?
    /// Copies these photos in the library; nil leaves the command out.
    var onDuplicate: (([LibraryAsset.ID]) -> Void)?
    /// Deletes these photos, after confirmation; nil leaves the command out.
    var onDelete: (([LibraryAsset.ID]) -> Void)?
    /// Told which month is at the top, and asked to scroll to another; nil for a grid without the toolbar's month button.
    var navigator: TimelineNavigator?
    /// Told how to read where this grid is scrolled, and where to scroll it when it takes the place
    /// of another; nil for a grid that always starts at the top.
    var place: GridPlaceKeeper?

    /// Thumbnail size and shape, from the toolbar's slider and the View menu; kept across launches.
    @AppStorage(GridDisplay.thumbnailSideKey) private var thumbnailSide = GridDisplay.defaultSide
    @AppStorage(GridDisplay.thumbnailFitKey) private var thumbnailFit = ThumbnailFit.fill
    /// Index of the last plain click, where a ⇧-click range starts.
    @State private var anchorIndex: Int?
    /// Index of the photo last clicked or moved to, where the arrow keys move from.
    @State private var cursorIndex: Int?
    /// The grid takes the keyboard focus when a photo is clicked, as a collection view becomes first
    /// responder: otherwise the sidebar's list keeps it and the arrow keys change the library.
    @FocusState private var isFocused: Bool
    @State private var batchError: String?
    @State private var exportModel: ExportModel?
    @State private var actions = AssetGridActions()
    /// Bumped when a menu opens, so the one rebuild SwiftUI makes of an open menu's items at the first
    /// update of the window happens right then, before a submenu could be open. See `AssetGridCell`.
    @State private var menuNudge = 0
    /// Bumped when a menu closes, and given to every cell: see `selectPhotoOfOpeningMenu`.
    @State private var menuGeneration = 0
    /// Where the grid is scrolled and how wide it is, for keeping the top row in place while zooming.
    /// A plain object: it changes on every scroll frame and must not rebuild the grid.
    @State private var viewport = GridViewport()
    @State private var scrollPosition = ScrollPosition()
    /// The thumbnail size when a pinch began; nil between pinches.
    @State private var pinchBaseSide: Double?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = menuNudge
        let _ = updateActions()
        let canPaste = AdjustmentsClipboard.shared.adjustments != nil
        let canAdjustDate = onAdjustDate != nil && source.capabilities.contains(.captureDate)
        let location = onLocation == nil || !source.capabilities.contains(.location) ? nil
            : AssetGridCell.LocationState(canRevert: source.capabilities.contains(.originalLocation))
        let canShowInFinder = source.hasFileURLs
        let canDuplicate = onDuplicate != nil && source.capabilities.contains(.duplication)
        let canDelete = onDelete != nil && source.capabilities.contains(.deletion)
        let albumState = albums.map(AssetGridCell.AlbumState.init)
        // What the selected photos share, read once per update: a cell reads only its own row.
        let selectionDecisions = sharedDecisions()
        let side = CGFloat(thumbnailSide)
        let timeline = sections
        let _ = followVisibleRows(in: timeline)
        let _ = tellPlace()
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side), spacing: GridViewport.spacing)], spacing: GridViewport.spacing) {
                ForEach(timeline.sections) { section in
                    Section {
                        // Iterate indices, not elements: ForEach over elements walks the whole collection to compute
                        // identities, which is far too slow for a lazily computed library of tens of thousands of rows.
                        ForEach(section.range, id: \.self) { index in
                            // A cell reads the listing, so it is asked again when the listing changes, and
                            // that can come before the months above are: with the row it had, which a
                            // listing that just shrank (a subfolder opened, a filter set) no longer has.
                            // The check is inside a ZStack so that every row is exactly one view. With the
                            // `if` alone a row is zero or one view, the grid can't tell where a row is
                            // without building every row above it, and did so at each update: measured
                            // with 74,000 photos, 124 ms to select a photo in the middle of the grid
                            // against 13 ms, and up to 500 ms per step of a change of width against 42 ms.
                            ZStack {
                                if source.assets.indices.contains(index) {
                                    let asset = source.assets[index]
                                    AssetGridCell(asset: asset, index: index, side: side, fit: thumbnailFit, isSelected: selection.contains(asset.id),
                                                  menu: AssetGridCell.MenuState(count: actsOnSelection(asset) ? selection.count : 1, canPaste: canPaste,
                                                                                canAdjustDate: canAdjustDate, location: location,
                                                                                canShowInFinder: canShowInFinder, canDuplicate: canDuplicate,
                                                                                canDelete: canDelete, albums: albumState,
                                                                                decisions: selectionDecisions.map { decisionState(of: asset, sharing: $0) },
                                                                                generation: menuGeneration),
                                                  source: source, actions: actions)
                                        .equatable()
                                }
                            }
                        }
                    } header: {
                        if source.timeline != nil, let title = MonthFormat.title(section.id) {
                            GridSectionHeader(title: title, count: section.range.count)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport.headerHeight = $0 }
                        }
                    }
                }
            }
            .padding(GridViewport.padding)
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        // Through `actions`: while a key is held, SwiftUI calls the handler of the first press
        // again, whose `selection` binding still holds the value of that moment, so every repeat
        // moved from the same photo (seen with a probe).
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            actions.move(GridMove(press.key), press.modifiers.contains(.shift))
            return .handled
        }
        // Back from the editor, the photo just edited is selected: the arrow keys go on from it.
        .onAppear {
            if !selection.isEmpty {
                isFocused = true
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            let held = viewport.update(geometry)
            // The first report is when the grid can scroll; the later ones find a listing that came late.
            // A place the grid was asked to open at comes before the one it holds while its width changes.
            if !restorePlace(), let held, source.assets.indices.contains(held.row) {
                scrollPosition.scrollTo(id: held.row, anchor: viewport.anchor(forCellTop: held.top, side: thumbnailSide))
            }
        }
        .onChange(of: place?.pending) { restorePlace() }
        .onChange(of: navigator?.jump) { _, jump in
            // The first row of the month goes under its header, which then sits at the top of the grid.
            guard let jump, source.assets.indices.contains(jump.row) else { return }
            scrollPosition.scrollTo(id: jump.row, anchor: viewport.anchor(underHeaderForSide: thumbnailSide))
        }
        // The months can change under a grid that doesn't move: the dates read late, a photo added.
        .onChange(of: source.timeline, initial: true) { reportVisible(rows: viewport.visibleRows, in: sections) }
        // Pinching the trackpad zooms the grid, as in Photos; the scroll gesture is a distinct event.
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                if pinchBaseSide == nil {
                    pinchBaseSide = thumbnailSide
                    // The photo under the pointer stays under it for the whole pinch.
                    viewport.beginPinch(at: value.startLocation)
                }
                let base = pinchBaseSide ?? thumbnailSide
                thumbnailSide = min(max(base * value.magnification, GridDisplay.sideRange.lowerBound), GridDisplay.sideRange.upperBound)
            }
            .onEnded { _ in
                pinchBaseSide = nil
                viewport.endPinch()
            })
        .onChange(of: thumbnailSide) { _, newSide in
            // Whatever changed the size (pinch, slider, menu), one photo stays where it is: the one
            // under the pointer for a pinch, the one at the center of the view otherwise.
            if let target = viewport.target(forSide: newSide) {
                scrollPosition.scrollTo(id: target.item, anchor: target.anchor)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuNudge += 1
            selectPhotoOfOpeningMenu()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuGeneration += 1 }
        // View › Zoom In, Zoom Out and the thumbnail shape act on this grid while it is shown.
        .focusedSceneValue(\.hasAssetGrid, true)
        .focusedSceneValue(\.exportAction, selection.isEmpty ? nil : ExportAction { export(source.assets(withIDs: selection)) })
        .focusedSceneValue(\.showInFinderAction, canShowInFinder && !selection.isEmpty ? ShowInFinderAction { showInFinder(selection) } : nil)
        .sheet(isPresented: Binding(get: { exportModel != nil }, set: {
            if !$0 {
                exportModel = nil
            }
        })) {
            if let exportModel {
                ExportView(model: exportModel) { self.exportModel = nil }
            }
        }
        .background {
            // Keyboard: Escape clears the selection, ⌘A selects every photo shown.
            Button("") { selection.removeAll() }.keyboardShortcut(.cancelAction).hidden()
            Button("") { selection = Set(source.assets.map(\.id)) }.keyboardShortcut("a").hidden()
        }
        .alert("Adjustments", isPresented: Binding(get: { batchError != nil }, set: {
            if !$0 {
                batchError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(batchError ?? "")
        }
        .overlay {
            if source.assets.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("This library doesn't contain any images."))
            }
        }
    }

    /// The sections to lay the rows out in: the source's months made to cover exactly the rows listed
    /// now, or all the rows as one section without a header when the source has no timeline.
    private var sections: DateTimeline {
        let count = source.assets.count
        return (source.timeline ?? .undated(count: count)).fitted(to: count)
    }

    /// Has the viewport tell which rows are on screen, as the grid scrolls. Not a state change: a
    /// plain object, pointed at this version of the sections.
    private func followVisibleRows(in timeline: DateTimeline) {
        if source.timeline == nil {
            viewport.headerHeight = 0
        }
        viewport.onVisibleRowsChange = { rows in reportVisible(rows: rows, in: timeline) }
    }

    /// Tells the navigator the month at the top of the grid and the dates of the photos on screen,
    /// from the first to the last row showing. Only when the photos are sorted by date: in any other
    /// order the photos on screen aren't a period.
    private func reportVisible(rows: ClosedRange<Int>?, in timeline: DateTimeline) {
        guard let navigator else { return }
        guard source.timeline != nil, let rows, source.assets.indices.contains(rows.upperBound) else {
            navigator.gridShows(section: nil, dates: nil)
            return
        }
        let dates = [source.assets[rows.lowerBound].creationDate, source.assets[rows.upperBound].creationDate].compactMap(\.self)
        navigator.gridShows(section: timeline.section(containing: rows.lowerBound)?.id,
                            dates: dates.min().flatMap { first in dates.max().map { first ... $0 } })
    }

    /// Has the keeper read where this grid is scrolled: the first thumbnail showing whole, and how
    /// far under the top. Not a state change: a plain closure, pointed at this version of the grid.
    private func tellPlace() {
        guard let place else { return }
        let viewport = viewport
        place.read = {
            guard let cell = viewport.topCell, source.assets.indices.contains(cell.row) else { return nil }
            return GridPlace(assetID: source.assets[cell.row].id, row: cell.row, top: cell.top)
        }
    }

    /// Scrolls to the place kept for this grid, once it has a size and photos to show, and again
    /// while that size settles (see `GridViewport.arrive(at:)`).
    @discardableResult
    private func restorePlace() -> Bool {
        if let place, let wanted = place.pending, viewport.hasSize, !source.assets.isEmpty {
            place.pending = nil
            viewport.arrive(at: wanted)
            scroll(to: wanted)
            return true
        }
        if let wanted = viewport.placeToAlignAgain() {
            scroll(to: wanted)
            return true
        }
        return false
    }

    private func scroll(to wanted: GridPlace) {
        guard !source.assets.isEmpty else { return }
        // The listing may have changed since: the photo is looked for, then its old row is settled for.
        let stillThere = source.assets.indices.contains(wanted.row) && source.assets[wanted.row].id == wanted.assetID
        let row = stillThere ? wanted.row : source.index(of: wanted.assetID) ?? min(wanted.row, source.assets.count - 1)
        scrollPosition.scrollTo(id: row, anchor: wanted.top.map { viewport.anchor(forCellTop: $0, side: thumbnailSide) } ?? .center)
    }

    /// Points the cells' actions at this version of the grid. Not a state change: a plain object.
    private func updateActions() {
        actions.open = onOpen
        actions.click = { id, index in click(id, at: index, modifiers: NSEvent.modifierFlags) }
        actions.move = { move, extending in moveSelection(move, extending: extending) }
        let pixels = GridDisplay.requestPixels(forSide: CGFloat(thumbnailSide), displayScale: displayScale)
        let fit = thumbnailFit
        actions.appear = { index in source.prefetchThumbnails(around: index, pixelSize: pixels, fit: fit) }
        let viewport = viewport
        actions.layout = { index, frame in viewport.cellDidLayout(index, frame: frame) }
        actions.disappear = { index in viewport.cellDidDisappear(index) }
        actions.copyAdjustments = { asset in run { try await BatchEditing.copyAdjustments(of: asset, from: source) } }
        actions.pasteAdjustments = { asset in
            run { try await BatchEditing.pasteAdjustments(to: targets(for: asset), in: source, undoManager: undoManager) }
        }
        actions.adjustDate = { asset in onAdjustDate?(targets(for: asset)) }
        actions.location = { command, asset in onLocation?(command, targetIDs(for: asset)) }
        actions.export = { asset in export(targets(for: asset)) }
        actions.showInFinder = { asset in showInFinder(Set(targetIDs(for: asset))) }
        actions.duplicate = { asset in onDuplicate?(targetIDs(for: asset)) }
        actions.delete = { asset in onDelete?(targetIDs(for: asset)) }
        actions.decide = { decision, asset in
            run { try await MetadataEditing.apply(targets(for: asset).map { ($0, decision) }, in: source, undoManager: undoManager) }
        }
        actions.targetIDs = targetIDs(for:)
        actions.albums = albums
    }

    // MARK: - Selection

    private func click(_ id: LibraryAsset.ID, at index: Int, modifiers: NSEvent.ModifierFlags) {
        isFocused = true
        cursorIndex = index
        if modifiers.contains(.command) {
            toggle(id, at: index)
        } else if modifiers.contains(.shift) {
            extend(to: index)
        } else {
            select(id, at: index)
        }
    }

    private func select(_ id: LibraryAsset.ID, at index: Int) {
        selection = [id]
        anchorIndex = index
    }

    private func toggle(_ id: LibraryAsset.ID, at index: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
            anchorIndex = index
        }
    }

    /// A secondary click on a photo outside the selection selects that photo, as in Photos and the
    /// Finder: the menu then acts on what shows as selected, and the Info panel tells about the
    /// same photo. A click on a selected photo keeps the selection, which the menu acts on.
    ///
    /// SwiftUI has no word for "this view's context menu is opening". The cell's menu tells when it
    /// is built (`ContextMenuOpening`), and a menu that starts being tracked right then is that one;
    /// the selection changes in the update the grid makes at that moment anyway (`menuNudge`).
    /// SwiftUI only builds a menu again when its content changed: every cell is given a new
    /// `menuGeneration` once a menu has closed, so the next one to open tells again.
    private func selectPhotoOfOpeningMenu() {
        guard let opening = actions.takeMenuOpening(), !selection.contains(opening.id),
              source.assets.indices.contains(opening.index), source.assets[opening.index].id == opening.id else { return }
        select(opening.id, at: opening.index)
    }

    private func extend(to index: Int) {
        selection.formUnion(ids(between: anchorIndex ?? index, and: index))
    }

    private func ids(between first: Int, and last: Int) -> [LibraryAsset.ID] {
        let assets = source.assets
        return (min(first, last) ... max(first, last)).compactMap { assets.indices.contains($0) ? assets[$0].id : nil }
    }

    /// Moves the selection to the photo next to the one last clicked or moved to, in the grid's rows
    /// and months, and scrolls it into view. With ⇧, the selection runs from the anchor to that
    /// photo, growing or shrinking as in a list. Without a selection, the first photo on screen is
    /// selected.
    private func moveSelection(_ move: GridMove, extending: Bool) {
        let assets = source.assets
        guard !assets.isEmpty else { return }
        guard let from = keyboardPosition() else {
            let first = viewport.visibleRows?.lowerBound ?? 0
            if assets.indices.contains(first) {
                select(assets[first].id, at: first)
                cursorIndex = first
            }
            return
        }
        let timeline = sections
        guard let to = timeline.row(from: from, moving: move, columns: viewport.columns(forSide: thumbnailSide)),
              assets.indices.contains(to) else { return }
        if extending {
            let anchor = anchorIndex.flatMap { assets.indices.contains($0) ? $0 : nil } ?? from
            anchorIndex = anchor
            selection = Set(ids(between: anchor, and: to))
        } else {
            select(assets[to].id, at: to)
        }
        cursorIndex = to
        guard !viewport.showsWhole(to) else { return }
        // A row that starts its month shows with the month's name above it.
        let startsSection = timeline.section(containing: to).map { to - $0.range.lowerBound < viewport.columns(forSide: thumbnailSide) } ?? false
        let anchor: UnitPoint = switch move {
        case .up, .left: startsSection && source.timeline != nil ? viewport.anchor(underHeaderForSide: thumbnailSide) : .top
        case .down, .right: .bottom
        }
        scrollPosition.scrollTo(id: to, anchor: anchor)
    }

    /// Where the arrow keys move from: the photo last clicked or moved to while it stays selected,
    /// else a selected photo, for a selection made elsewhere (the Info panel, the map).
    private func keyboardPosition() -> Int? {
        let assets = source.assets
        if let cursorIndex, assets.indices.contains(cursorIndex), selection.contains(assets[cursorIndex].id) {
            return cursorIndex
        }
        return selection.first.flatMap(source.index(of:))
    }

    /// The photos a context menu acts on: the whole selection when the clicked photo is part of it,
    /// in the grid's order (an export numbers its files in that order).
    /// Resolved only when the action runs: SwiftUI may build menu content for every visible tile, and
    /// walking a 74,000-photo collection there froze the grid on each click.
    private func showInFinder(_ ids: Set<LibraryAsset.ID>) {
        FinderReveal.show(source.fileURLs(for: source.assets(withIDs: ids)))
    }

    private func targets(for asset: LibraryAsset) -> [LibraryAsset] {
        guard actsOnSelection(asset) else { return [asset] }
        return source.assets(withIDs: selection)
    }

    /// The same photos by identifier, for what needs nothing else: no lookup, whatever the selection's size.
    private func targetIDs(for asset: LibraryAsset) -> [LibraryAsset.ID] {
        selection.contains(asset.id) ? Array(selection) : [asset.id]
    }

    /// The rating rows of the context menus as the selected photos share them: nil values when they
    /// differ, or when the selection is too large to look up on every update. Nil where the library
    /// stores neither rating nor flag.
    private func sharedDecisions() -> AssetGridCell.DecisionState? {
        let canRate = source.capabilities.contains(.rating)
        let canFlag = source.capabilities.contains(.flag)
        guard canRate || canFlag else { return nil }
        // Too many to look up: Remove Rating and Remove Flag are offered, in case.
        var state = AssetGridCell.DecisionState(rating: nil, flag: nil, hasRating: true, hasFlag: true, canRate: canRate, canFlag: canFlag)
        if selection.count > 1, selection.count <= AssetInfoModel.selectionLimit {
            let assets = selection.compactMap { source.asset(id: $0) }
            state.rating = AssetInfoModel.shared(assets.map(\.rating))
            state.flag = AssetInfoModel.shared(assets.map(\.flag))
            state.hasRating = assets.contains { $0.rating > 0 }
            state.hasFlag = assets.contains { $0.flag != .none }
        }
        return state
    }

    /// The rating rows of a photo's context menu: the selection's when the menu acts on it, else the photo's own.
    private func decisionState(of asset: LibraryAsset, sharing shared: AssetGridCell.DecisionState) -> AssetGridCell.DecisionState {
        guard !actsOnSelection(asset) else { return shared }
        var state = shared
        state.rating = asset.rating
        state.flag = asset.flag
        state.hasRating = asset.rating > 0
        state.hasFlag = asset.flag != .none
        return state
    }

    private func actsOnSelection(_ asset: LibraryAsset) -> Bool {
        selection.contains(asset.id) && selection.count > 1
    }

    private func export(_ assets: [LibraryAsset]) {
        guard !assets.isEmpty else { return }
        exportModel = ExportModel(items: assets.map { ExportItem.make(for: $0, in: source) })
    }
}

private extension AssetGridView {
    /// Runs a grid action and shows its error, if any.
    func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                batchError = error.localizedDescription
            }
        }
    }
}

/// The grid's scroll offset and size as last reported, and the arithmetic of its rows: `LazyVGrid`
/// with adaptive columns puts `floor((width + spacing) / (minimum + spacing))` cells per row, every
/// row is a thumbnail (its square plus the 2-point selection padding) and the row spacing high, and
/// the columns share the width left (measured with a probe, see docs/PLAN.md).
///
/// While the size changes, one photo is kept where it is on screen: the one under the pointer for a
/// pinch, the one at the center of the view for the slider and the menu. It is fixed once, at the
/// first change of a continuous zoom, and every offset is derived from it: the offset reported runs
/// an update behind the one the grid asked for, and reading it back at each step made the error
/// compound (a visible scroll while zooming). The anchor is dropped when the user scrolls, that is
/// when the offset reported isn't the one asked for; never during a pinch.
/// The grid's visible area and the on-screen frames of its visible cells, and from them the photo to
/// keep in place while the thumbnail size changes: the one under the pointer for a pinch, the one at
/// the center of the view for the slider and the menu.
///
/// The photo is fixed once, at the first change of a continuous zoom, then positioned by identity with
/// `ScrollPosition.scrollTo(id:anchor:)`, never by a computed offset: `LazyVGrid` keeps estimated
/// heights for the rows it hasn't laid out again, which converge over a second after a change of size
/// (measured with a probe, see docs/PLAN.md), so an offset computed from uniform rows lands anywhere.
/// The anchor is dropped when the pinch ends, or when the slider or the menu haven't moved for a
/// moment; a scroll by the user in between then starts from where they are.
@MainActor
final class GridViewport {
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 8
    /// Changes closer together than this belong to one zoom, and keep its anchor.
    private static let zoomGap: Duration = .milliseconds(400)

    /// A photo and where it is on screen: its index, the anchored point's distance from the top of the
    /// visible area, and where that point is inside the cell, as a fraction of its height.
    private struct Anchor {
        var item: Int
        var pointY: CGFloat
        var fractionInCell: CGFloat
    }

    /// The scroll view's container: the part of it not under the toolbar or a banner. Its top left
    /// corner is the origin of the cells' frames, of the pinch's location and of
    /// `scrollTo(id:anchor:)`'s alignment, and where section headers pin (measured with a probe in
    /// a real window: a first cell reported at y = 50 sits 50 points under the toolbar, and the
    /// container is the window's height less the toolbar's).
    private var containerSize: CGSize = .zero
    /// Frames of the cells on screen, in the scroll view's coordinate space.
    private var frames: [Int: CGRect] = [:]
    private var anchor: Anchor?
    private var isPinching = false
    private var lastZoom: ContinuousClock.Instant?

    /// Height of the month headers, each above the first row of its month; 0 when the grid has none.
    var headerHeight: CGFloat = 0
    /// The first and the last row showing; nil when no cell is on screen.
    private(set) var visibleRows: ClosedRange<Int>?
    /// Called when `visibleRows` changes: a few times a second while scrolling, not on every frame.
    var onVisibleRowsChange: (ClosedRange<Int>?) -> Void = { _ in }
    private var visibleRowsAreOutdated = false

    /// Where the grid was last seen scrolled while its width stayed the same: read once the cells
    /// have reported their frames (`updateVisibleRows`), which the scroll view's own report precedes.
    private var settled: (row: Int, top: CGFloat)?
    /// The thumbnail kept where it is while the width changes, and when the width last changed.
    private var held: (row: Int, top: CGFloat)?
    private var lastResize: ContinuousClock.Instant?
    /// The height of the grid's content as last reported, and how many reports came since the
    /// width last changed.
    private var contentHeight: CGFloat = 0
    private var reportsSinceResize = Int.max / 2
    /// Changes of width closer together than this belong to one resize (the sidebar sliding, the
    /// window's edge being dragged), and keep the same thumbnail in place.
    private static let resizeGap: Duration = .milliseconds(400)

    /// Takes the scroll view's geometry as it changes. While the width of the visible area changes,
    /// answers with the thumbnail to put back where it was each time the rows were made anew: more
    /// or fewer columns make other rows, and the same offset would show other photos (hiding the
    /// sidebar scrolled to older ones). The thumbnail is the one that was first before the resize
    /// began, for the whole of it: reading it again between two steps would take a grid that has
    /// not caught up yet.
    ///
    /// The rows are known to have changed by the height of the content: between two widths that
    /// hold as many columns it stays the same, and so does what the grid shows. Aligning at every
    /// step of the sidebar's animation cost as much again as the layout itself (measured with a
    /// probe, see docs/PLAN.md); aligning once at the first step lost the place at the next change
    /// of columns.
    func update(_ geometry: ScrollGeometry) -> (row: Int, top: CGFloat)? {
        let previous = containerSize
        containerSize = geometry.containerSize
        let rowsChanged = geometry.contentSize.height != contentHeight
        contentHeight = geometry.contentSize.height
        guard previous.width > 0, previous.width != containerSize.width else {
            if !isResizing {
                held = nil
            }
            // The new height can come one report after the new width.
            defer { reportsSinceResize += 1 }
            return rowsChanged && reportsSinceResize < 2 ? held : nil
        }
        if !isResizing || held == nil {
            held = settled
        }
        lastResize = .now
        reportsSinceResize = 0
        return rowsChanged ? held : nil
    }

    private var isResizing: Bool {
        lastResize.map { ContinuousClock.now - $0 < Self.resizeGap } ?? false
    }

    /// The place the grid was last asked to open at, the size of the visible area it was aligned
    /// in, and until when it is worth aligning again.
    private var arrival: (place: GridPlace, size: CGSize, until: ContinuousClock.Instant)?
    /// How long after a grid opened at a place its size may still be settling.
    private static let settlingTime: Duration = .seconds(1)

    /// Notes that the grid was just scrolled to `place`. A window lays its columns out in several
    /// passes when a library's view appears (measured with a probe: a visible area of 100 × 100,
    /// then 24 wide, then the real one), and a scroll made in a provisional size is lost: the place
    /// is aligned again each time the size changes, for a moment.
    func arrive(at place: GridPlace) {
        arrival = (place, containerSize, .now + Self.settlingTime)
    }

    /// The place to scroll to again, when the visible area changed size since it was last aligned.
    func placeToAlignAgain() -> GridPlace? {
        guard let current = arrival else { return nil }
        guard ContinuousClock.now < current.until else {
            arrival = nil
            return nil
        }
        guard hasSize, current.size != containerSize else { return nil }
        arrival?.size = containerSize
        return current.place
    }

    /// How many thumbnails a row holds when they are `side` wide: the arithmetic of `LazyVGrid`'s
    /// adaptive columns, in the width the padding leaves.
    func columns(forSide side: Double) -> Int {
        let width = containerSize.width - 2 * Self.padding
        return max(Int(((width + Self.spacing) / (side + Self.spacing)).rounded(.down)), 1)
    }

    /// True when the cell is laid out and shows whole in the visible area.
    func showsWhole(_ index: Int) -> Bool {
        guard let frame = frames[index] else { return false }
        return frame.minY >= 0 && frame.maxY <= containerSize.height
    }

    /// False until the scroll view has reported its size: nothing can be aligned in it before.
    var hasSize: Bool {
        containerSize.height > 0
    }

    /// The first thumbnail showing whole, and how far its top is under the top of the visible area:
    /// what tells where the grid is scrolled. The first one showing at all when none shows whole
    /// (thumbnails taller than the window); nil when no cell is on screen.
    var topCell: (row: Int, top: CGFloat)? {
        var whole: (row: Int, top: CGFloat)?
        var cut: (row: Int, top: CGFloat)?
        for (index, frame) in frames where frame.maxY > 0 && frame.minY < containerSize.height {
            if frame.minY >= 0 {
                if index < whole?.row ?? .max {
                    whole = (index, frame.minY)
                }
            } else if index < cut?.row ?? .max {
                cut = (index, frame.minY)
            }
        }
        return whole ?? cut
    }

    func cellDidLayout(_ index: Int, frame: CGRect) {
        frames[index] = frame
        setNeedsVisibleRows()
    }

    func cellDidDisappear(_ index: Int) {
        frames[index] = nil
        setNeedsVisibleRows()
    }

    /// Every cell on screen reports its frame on each scroll frame: the rows showing are worked out
    /// once they all have, at the next turn of the main actor, rather than once per cell.
    private func setNeedsVisibleRows() {
        guard !visibleRowsAreOutdated else { return }
        visibleRowsAreOutdated = true
        Task { [weak self] in self?.updateVisibleRows() }
    }

    private func updateVisibleRows() {
        visibleRowsAreOutdated = false
        if !isResizing {
            settled = topCell
        }
        var first: Int?
        var last: Int?
        // The grid keeps a few cells beyond its edges: only those crossing the visible area count.
        for (index, frame) in frames where frame.maxY > 0 && frame.minY < containerSize.height {
            first = min(first ?? index, index)
            last = max(last ?? index, index)
        }
        let rows = first.flatMap { first in last.map { first ... $0 } }
        guard rows != visibleRows else { return }
        visibleRows = rows
        onVisibleRowsChange(rows)
    }

    /// How to align a row with the visible area so it shows right under its header, when the row is
    /// the first of its section: the header then sits at the very top of the grid.
    func anchor(underHeaderForSide side: Double) -> UnitPoint {
        unitPoint(forCellTop: headerHeight + Self.spacing, side: side)
    }

    /// `location` is the pointer in the scroll view's coordinate space.
    func beginPinch(at location: CGPoint) {
        anchor = makeAnchor(at: location)
        isPinching = true
    }

    func endPinch() {
        isPinching = false
        anchor = nil
    }

    /// The cell to scroll to, and how to align it with the visible area, so the anchored point stays
    /// put once thumbnails are `side` wide; nil when no cell is on screen.
    func target(forSide side: Double) -> (item: Int, anchor: UnitPoint)? {
        let now = ContinuousClock.now
        if !isPinching, let lastZoom, now - lastZoom > Self.zoomGap {
            anchor = nil
        }
        lastZoom = now
        guard let anchor = anchor ?? makeAnchor(at: CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)) else { return nil }
        self.anchor = anchor
        let top = anchor.pointY - anchor.fractionInCell * (side + 4)
        return (anchor.item, unitPoint(forCellTop: top, side: side))
    }

    /// How to align a cell with the visible area so its top is `top` points under the top of it:
    /// where `topCell` found it.
    func anchor(forCellTop top: CGFloat, side: Double) -> UnitPoint {
        unitPoint(forCellTop: top, side: side)
    }

    /// The alignment that puts the top of a cell `top` points under the top of the visible area, once
    /// thumbnails are `side` wide.
    private func unitPoint(forCellTop top: CGFloat, side: Double) -> UnitPoint {
        let cellHeight = side + 4
        // A unit point u aligns the cell's point at u of its height with the container's point at u of
        // its height, so the cell's top lands at u * (container - cell).
        let room = containerSize.height - cellHeight
        return UnitPoint(x: 0, y: room > 0 ? min(max(top / room, 0), 1) : 0)
    }

    /// The cell under `point`, or the nearest one when the point is between cells.
    private func makeAnchor(at point: CGPoint) -> Anchor? {
        guard let (item, frame) = frames.min(by: { Self.distance(from: point, to: $0.value) < Self.distance(from: point, to: $1.value) }) else {
            return nil
        }
        return Anchor(item: item, pointY: point.y, fractionInCell: (point.y - frame.minY) / frame.height)
    }

    private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}

/// What a cell asks of its grid. One object, the same from one update to the next, where closures
/// passed to the cell would be new ones each time and make every cell look changed.
@MainActor
final class AssetGridActions {
    var open: (LibraryAsset.ID) -> Void = { _ in }
    var click: (LibraryAsset.ID, Int) -> Void = { _, _ in }
    /// An arrow key, and whether ⇧ is held.
    var move: (GridMove, Bool) -> Void = { _, _ in }
    var appear: (Int) -> Void = { _ in }
    var disappear: (Int) -> Void = { _ in }
    /// The cell's frame in the scroll view's coordinate space, whenever it changes.
    var layout: (Int, CGRect) -> Void = { _, _ in }
    var copyAdjustments: (LibraryAsset) -> Void = { _ in }
    var pasteAdjustments: (LibraryAsset) -> Void = { _ in }
    var adjustDate: (LibraryAsset) -> Void = { _ in }
    var location: (LocationCommand, LibraryAsset) -> Void = { _, _ in }
    var export: (LibraryAsset) -> Void = { _ in }
    var showInFinder: (LibraryAsset) -> Void = { _ in }
    var duplicate: (LibraryAsset) -> Void = { _ in }
    var delete: (LibraryAsset) -> Void = { _ in }
    /// Writes a rating or a flag to the photos the menu acts on.
    var decide: (LibraryDecision, LibraryAsset) -> Void = { _, _ in }
    /// The photos a context menu acts on, by identifier: the selection when the photo is part of it.
    var targetIDs: (LibraryAsset) -> [LibraryAsset.ID] = { [$0.id] }
    var albums: AlbumsAction?

    /// The photo whose context menu was last built, and when.
    private var menuOpening: (id: LibraryAsset.ID, index: Int, at: ContinuousClock.Instant)?
    /// A menu is tracked right after it is built: one built longer ago than this isn't the menu
    /// that is opening now (the menu bar, a pop-up button).
    private static let menuOpeningDelay = Duration.milliseconds(500)

    /// Called while the context menu of a photo is being built for display.
    func menuIsOpening(for id: LibraryAsset.ID, at index: Int) {
        menuOpening = (id, index, .now)
    }

    /// The photo whose context menu is opening now, if any; asked once per menu.
    func takeMenuOpening() -> (id: LibraryAsset.ID, index: Int)? {
        defer { menuOpening = nil }
        guard let menuOpening, ContinuousClock.now - menuOpening.at < Self.menuOpeningDelay else { return nil }
        return (menuOpening.id, menuOpening.index)
    }
}

/// Tells when the context menu it is placed in is built for display. SwiftUI runs a context menu's
/// closure for every tile on every update of the grid, but evaluates the body of a view inside it
/// only when the menu opens, and then only if what it holds changed since it last did (measured
/// with a probe, see docs/PLAN.md): that body is the one place that knows a menu is opening, and
/// for which photo. It must hold items of the menu: a view that adds none is never evaluated.
private struct ContextMenuOpening<Items: View>: View {
    let report: () -> Void
    @ViewBuilder let items: Items

    var body: some View {
        // Not a state change: the report goes to a plain object.
        let _ = report()
        items
    }
}

/// One thumbnail of the grid with its gestures, its context menu and its drag source.
///
/// Equatable, with inputs that only change when the photo, the selection, the zoom or what the menu
/// offers does: an update of the view holding a context menu makes SwiftUI replace every item of the open
/// menu, which closes the submenu the pointer is in (Add to Album), while the menu itself stays.
/// Measured with a probe: the items are replaced on every update of that view, whatever the content;
/// with the content unchanged, only once, at the first update of the window after the menu opened,
/// which the grid triggers itself as soon as a menu opens (`menuNudge`).
struct AssetGridCell: View, Equatable {
    /// What the context menu shows, beyond the photo itself.
    nonisolated struct MenuState: Equatable {
        /// The photos the menu acts on: the selection when the photo is part of it, else 1.
        var count: Int
        var canPaste: Bool
        var canAdjustDate: Bool
        /// Nil where the library stores no location: the Location submenu is left out.
        var location: LocationState?
        /// The photo is a file of a folder, which the Finder can show.
        var canShowInFinder: Bool
        var canDuplicate: Bool
        var canDelete: Bool
        var albums: AlbumState?
        /// Nil where the library stores neither rating nor flag: the rows are left out.
        var decisions: DecisionState?
        /// Changes after each menu closed, so the menu is built anew the next time it opens.
        var generation = 0
    }

    /// What the Location submenu offers.
    nonisolated struct LocationState: Equatable {
        /// The library keeps the original location apart, to go back to.
        var canRevert: Bool
    }

    /// What the rating and flag rows show and offer.
    nonisolated struct DecisionState: Equatable {
        /// The rating of the photos acted on; nil when they differ, or too many are selected to tell.
        var rating: Int?
        var flag: ItemFlag?
        /// Some photo acted on has a rating, or a flag: Remove Rating and Remove Flag are offered.
        var hasRating: Bool
        var hasFlag: Bool
        var canRate: Bool
        var canFlag: Bool
    }

    /// The album items depend on these; the closures of `AlbumsAction` are read from `actions`.
    nonisolated struct AlbumState: Equatable {
        var currentAlbumID: PhotosAlbum.ID?
        var lastAlbum: PhotosAlbum?
        var canRemove: Bool

        @MainActor init(_ albums: AlbumsAction) {
            currentAlbumID = albums.currentAlbumID
            lastAlbum = albums.lastAlbum
            canRemove = albums.remove != nil
        }
    }

    let asset: LibraryAsset
    let index: Int
    let side: CGFloat
    let fit: ThumbnailFit
    let isSelected: Bool
    let menu: MenuState
    let source: any LibrarySource
    let actions: AssetGridActions
    /// The source and the actions count by identity, which can be compared off the main actor.
    private nonisolated let identities: [ObjectIdentifier]

    init(asset: LibraryAsset, index: Int, side: CGFloat, fit: ThumbnailFit, isSelected: Bool, menu: MenuState,
         source: any LibrarySource, actions: AssetGridActions)
    {
        self.asset = asset
        self.index = index
        self.side = side
        self.fit = fit
        self.isSelected = isSelected
        self.menu = menu
        self.source = source
        self.actions = actions
        identities = [ObjectIdentifier(source), ObjectIdentifier(actions)]
    }

    var body: some View {
        AssetThumbnailView(asset: asset, source: source, side: side, fit: fit, isSelected: isSelected)
            .gesture(TapGesture(count: 2).onEnded { actions.open(asset.id) })
            // One tap gesture, dispatched on the modifiers held at the time: a plain TapGesture
            // also fires on modified clicks, so stacking modified variants would double up.
            .simultaneousGesture(TapGesture().onEnded { actions.click(asset.id, index) })
            .contextMenu { contextMenu }
            .modifier(PhotoDragSource(isEnabled: menu.albums != nil) { actions.targetIDs(asset) })
            .onAppear { actions.appear(index) }
            .onDisappear { actions.disappear(index) }
            // Where the cell is on screen, for the grid to know which photo is under the pointer.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { actions.layout(index, $0) }
    }

    @ViewBuilder
    private var contextMenu: some View {
        ContextMenuOpening(report: { actions.menuIsOpening(for: asset.id, at: index) }) {
            Button("Open in Editor") { actions.open(asset.id) }
        }
        if menu.canShowInFinder {
            Button("Show in Finder") { actions.showInFinder(asset) }
        }
        Divider()
        Button("Copy Adjustments") { actions.copyAdjustments(asset) }
            .disabled(!asset.hasEdit)
        Button(menu.count > 1 ? "Paste Adjustments to \(menu.count) Photos" : "Paste Adjustments") { actions.pasteAdjustments(asset) }
            .disabled(!menu.canPaste)
        if menu.canAdjustDate || menu.location != nil {
            Divider()
        }
        if menu.canAdjustDate {
            Button(menu.count > 1 ? "Adjust Date & Time of \(menu.count) Photos…" : "Adjust Date & Time…") { actions.adjustDate(asset) }
        }
        if let location = menu.location {
            // Whether the photos have a location to remove or revert isn't read here: the menu is
            // built for every thumbnail on every update. The items do nothing to photos they don't concern.
            Menu("Location") {
                Button("Assign Location…") { actions.location(.assign, asset) }
                    // The Info panel, where the place is chosen, shows that many photos at most.
                    .disabled(menu.count > AssetInfoModel.selectionLimit)
                Button("Remove Location") { actions.location(.remove, asset) }
                if location.canRevert {
                    Button("Revert to Original Location") { actions.location(.revert, asset) }
                }
            }
        }
        if menu.albums != nil {
            Divider()
            AlbumMenuItems(albums: actions.albums, placement: .contextMenu(count: menu.count)) { actions.targetIDs(asset) }
        }
        if let decisions = menu.decisions {
            Divider()
            DecisionMenuItems(placement: .contextMenu, rating: decisions.rating, flag: decisions.flag,
                              hasRating: decisions.hasRating, hasFlag: decisions.hasFlag,
                              setRating: decisions.canRate ? { actions.decide(.rating($0), asset) } : nil,
                              setFlag: decisions.canFlag ? { actions.decide(.flag($0), asset) } : nil)
        }
        Divider()
        if menu.canDuplicate {
            Button(PhotoFilingAction.duplicateTitle(count: menu.count)) { actions.duplicate(asset) }
        }
        Button(menu.count > 1 ? "Export \(menu.count) Photos…" : "Export…") { actions.export(asset) }
        if menu.canDelete {
            // Last and apart, as what destroys is in a context menu.
            Divider()
            Button(PhotoFilingAction.deleteTitle(count: menu.count), role: .destructive) { actions.delete(asset) }
        }
    }

    nonisolated static func == (lhs: AssetGridCell, rhs: AssetGridCell) -> Bool {
        lhs.asset == rhs.asset && lhs.index == rhs.index && lhs.side == rhs.side && lhs.fit == rhs.fit
            && lhs.isSelected == rhs.isSelected && lhs.menu == rhs.menu && lhs.identities == rhs.identities
    }
}

/// The header of a month in the grid: its name and how many photos it holds here, as a plain
/// title above its first row.
struct GridSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text("^[\(count) photo](inflect: true)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Sample library") {
    @Previewable @State var selection: Set<LibraryAsset.ID> = ["sample-1", "sample-2"]
    AssetGridView(source: SampleLibrarySource(), selection: $selection) { _ in }
        .frame(width: 720, height: 500)
}

#Preview("Months") {
    @Previewable @State var selection: Set<LibraryAsset.ID> = []
    AssetGridView(source: SampleLibrarySource(count: 60, daysApart: 4), selection: $selection) { _ in }
        .frame(width: 720, height: 500)
}

#Preview("Empty") {
    @Previewable @State var selection: Set<LibraryAsset.ID> = []
    AssetGridView(source: SampleLibrarySource(count: 0), selection: $selection) { _ in }
        .frame(width: 400, height: 300)
}

private extension GridMove {
    /// The move of an arrow key; only arrow keys are handed to the grid's key handler.
    init(_ key: KeyEquivalent) {
        self = switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
    }
}
