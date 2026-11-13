import AppKit
import EditorKit
import LibraryKit
import SwiftUI

/// Thumbnail grid shared by every library source, with multiple selection: click selects, ⌘-click
/// toggles, ⇧-click extends from the last click, double-click opens the editor.
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
    /// Filing in albums: its items in the context menu, and thumbnails that can be dragged to an
    /// album of the sidebar. Nil for libraries without albums.
    var albums: AlbumsAction?
    /// Told which month is at the top, and asked to scroll to another; nil for a grid without the toolbar's month button.
    var navigator: TimelineNavigator?

    /// Thumbnail size and shape, from the toolbar's slider and the View menu; kept across launches.
    @AppStorage(GridDisplay.thumbnailSideKey) private var thumbnailSide = GridDisplay.defaultSide
    @AppStorage(GridDisplay.thumbnailFitKey) private var thumbnailFit = ThumbnailFit.fill
    /// Index of the last plain click, where a ⇧-click range starts.
    @State private var anchorIndex: Int?
    @State private var batchError: String?
    @State private var exportModel: ExportModel?
    @State private var actions = AssetGridActions()
    /// Bumped when a menu opens, so the one rebuild SwiftUI makes of an open menu's items at the first
    /// update of the window happens right then, before a submenu could be open. See `AssetGridCell`.
    @State private var menuNudge = 0
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
        let canShowInFinder = source.hasFileURLs
        let albumState = albums.map(AssetGridCell.AlbumState.init)
        let side = CGFloat(thumbnailSide)
        let timeline = sections
        let _ = followVisibleRows(in: timeline)
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
                            if source.assets.indices.contains(index) {
                                let asset = source.assets[index]
                                AssetGridCell(asset: asset, index: index, side: side, fit: thumbnailFit, isSelected: selection.contains(asset.id),
                                              menu: AssetGridCell.MenuState(count: actsOnSelection(asset) ? selection.count : 1, canPaste: canPaste,
                                                                            canAdjustDate: canAdjustDate,
                                                                            canShowInFinder: canShowInFinder, albums: albumState),
                                              source: source, actions: actions)
                                    .equatable()
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
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
            viewport.update(geometry)
        }
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
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuNudge += 1 }
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

    /// Points the cells' actions at this version of the grid. Not a state change: a plain object.
    private func updateActions() {
        actions.open = onOpen
        actions.click = { id, index in click(id, at: index, modifiers: NSEvent.modifierFlags) }
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
        actions.export = { asset in export(targets(for: asset)) }
        actions.showInFinder = { asset in showInFinder(Set(targetIDs(for: asset))) }
        actions.targetIDs = targetIDs(for:)
        actions.albums = albums
    }

    // MARK: - Selection

    private func click(_ id: LibraryAsset.ID, at index: Int, modifiers: NSEvent.ModifierFlags) {
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

    private func extend(to index: Int) {
        let anchor = anchorIndex ?? index
        let range = min(anchor, index) ... max(anchor, index)
        let assets = source.assets
        selection.formUnion(range.compactMap { assets.indices.contains($0) ? assets[$0].id : nil })
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

    func update(_ geometry: ScrollGeometry) {
        containerSize = geometry.containerSize
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
    var appear: (Int) -> Void = { _ in }
    var disappear: (Int) -> Void = { _ in }
    /// The cell's frame in the scroll view's coordinate space, whenever it changes.
    var layout: (Int, CGRect) -> Void = { _, _ in }
    var copyAdjustments: (LibraryAsset) -> Void = { _ in }
    var pasteAdjustments: (LibraryAsset) -> Void = { _ in }
    var adjustDate: (LibraryAsset) -> Void = { _ in }
    var export: (LibraryAsset) -> Void = { _ in }
    var showInFinder: (LibraryAsset) -> Void = { _ in }
    /// The photos a context menu acts on, by identifier: the selection when the photo is part of it.
    var targetIDs: (LibraryAsset) -> [LibraryAsset.ID] = { [$0.id] }
    var albums: AlbumsAction?
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
        /// The photo is a file of a folder, which the Finder can show.
        var canShowInFinder: Bool
        var albums: AlbumState?
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
        Button("Open in Editor") { actions.open(asset.id) }
        if menu.canShowInFinder {
            Button("Show in Finder") { actions.showInFinder(asset) }
        }
        Divider()
        Button("Copy Adjustments") { actions.copyAdjustments(asset) }
            .disabled(!asset.hasEdit)
        Button(menu.count > 1 ? "Paste Adjustments to \(menu.count) Photos" : "Paste Adjustments") { actions.pasteAdjustments(asset) }
            .disabled(!menu.canPaste)
        if menu.canAdjustDate {
            Divider()
            Button(menu.count > 1 ? "Adjust Date & Time of \(menu.count) Photos…" : "Adjust Date & Time…") { actions.adjustDate(asset) }
        }
        if menu.albums != nil {
            Divider()
            AlbumMenuItems(albums: actions.albums, placement: .contextMenu(count: menu.count)) { actions.targetIDs(asset) }
        }
        Divider()
        Button(menu.count > 1 ? "Export \(menu.count) Photos…" : "Export…") { actions.export(asset) }
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
