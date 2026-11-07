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
struct AssetGridView: View {
    let source: any LibrarySource
    @Binding var selection: Set<LibraryAsset.ID>
    let onOpen: (LibraryAsset.ID) -> Void
    /// Opens the Adjust Date & Time dialog for these photos; nil leaves the command out.
    var onAdjustDate: (([LibraryAsset]) -> Void)?
    /// Filing in albums: its items in the context menu, and thumbnails that can be dragged to an
    /// album of the sidebar. Nil for libraries without albums.
    var albums: AlbumsAction?

    private let thumbnailSide: CGFloat = 160
    /// Index of the last plain click, where a ⇧-click range starts.
    @State private var anchorIndex: Int?
    @State private var batchError: String?
    @State private var exportModel: ExportModel?
    @State private var actions = AssetGridActions()
    /// Bumped when a menu opens, so the one rebuild SwiftUI makes of an open menu's items at the first
    /// update of the window happens right then, before a submenu could be open. See `AssetGridCell`.
    @State private var menuNudge = 0
    @Environment(\.undoManager) private var undoManager
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = menuNudge
        let _ = updateActions()
        let canPaste = AdjustmentsClipboard.shared.adjustments != nil
        let canAdjustDate = onAdjustDate != nil && source.capabilities.contains(.captureDate)
        let albumState = albums.map(AssetGridCell.AlbumState.init)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 8)], spacing: 8) {
                // Iterate indices, not elements: ForEach over elements walks the whole collection to compute
                // identities, which is far too slow for a lazily computed library of tens of thousands of rows.
                ForEach(source.assets.indices, id: \.self) { index in
                    let asset = source.assets[index]
                    AssetGridCell(asset: asset, index: index, side: thumbnailSide, isSelected: selection.contains(asset.id),
                                  menu: AssetGridCell.MenuState(count: actsOnSelection(asset) ? selection.count : 1, canPaste: canPaste,
                                                                canAdjustDate: canAdjustDate, albums: albumState),
                                  source: source, actions: actions)
                        .equatable()
                }
            }
            .padding(12)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuNudge += 1 }
        .focusedSceneValue(\.exportAction, selection.isEmpty ? nil : ExportAction { export(selection.compactMap { source.asset(id: $0) }) })
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

    /// Points the cells' actions at this version of the grid. Not a state change: a plain object.
    private func updateActions() {
        actions.open = onOpen
        actions.click = { id, index in click(id, at: index, modifiers: NSEvent.modifierFlags) }
        actions.appear = { index in
            source.prefetchThumbnails(around: index, pixelSize: CGSize(width: thumbnailSide * displayScale, height: thumbnailSide * displayScale))
        }
        actions.copyAdjustments = { asset in run { try await BatchEditing.copyAdjustments(of: asset, from: source) } }
        actions.pasteAdjustments = { asset in
            run { try await BatchEditing.pasteAdjustments(to: targets(for: asset), in: source, undoManager: undoManager) }
        }
        actions.adjustDate = { asset in onAdjustDate?(targets(for: asset)) }
        actions.export = { asset in export(targets(for: asset)) }
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

    /// The photos a context menu acts on: the whole selection when the clicked photo is part of it.
    /// Resolved only when the action runs: SwiftUI may build menu content for every visible tile, and
    /// walking a 74,000-photo collection there froze the grid on each click.
    private func targets(for asset: LibraryAsset) -> [LibraryAsset] {
        guard actsOnSelection(asset) else { return [asset] }
        return selection.compactMap { source.asset(id: $0) }
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

/// What a cell asks of its grid. One object, the same from one update to the next, where closures
/// passed to the cell would be new ones each time and make every cell look changed.
@MainActor
final class AssetGridActions {
    var open: (LibraryAsset.ID) -> Void = { _ in }
    var click: (LibraryAsset.ID, Int) -> Void = { _, _ in }
    var appear: (Int) -> Void = { _ in }
    var copyAdjustments: (LibraryAsset) -> Void = { _ in }
    var pasteAdjustments: (LibraryAsset) -> Void = { _ in }
    var adjustDate: (LibraryAsset) -> Void = { _ in }
    var export: (LibraryAsset) -> Void = { _ in }
    /// The photos a context menu acts on, by identifier: the selection when the photo is part of it.
    var targetIDs: (LibraryAsset) -> [LibraryAsset.ID] = { [$0.id] }
    var albums: AlbumsAction?
}

/// One thumbnail of the grid with its gestures, its context menu and its drag source.
///
/// Equatable, with inputs that only change when the photo, the selection or what the menu offers
/// does: an update of the view holding a context menu makes SwiftUI replace every item of the open
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
    let isSelected: Bool
    let menu: MenuState
    let source: any LibrarySource
    let actions: AssetGridActions
    /// The source and the actions count by identity, which can be compared off the main actor.
    private nonisolated let identities: [ObjectIdentifier]

    init(asset: LibraryAsset, index: Int, side: CGFloat, isSelected: Bool, menu: MenuState, source: any LibrarySource, actions: AssetGridActions) {
        self.asset = asset
        self.index = index
        self.side = side
        self.isSelected = isSelected
        self.menu = menu
        self.source = source
        self.actions = actions
        identities = [ObjectIdentifier(source), ObjectIdentifier(actions)]
    }

    var body: some View {
        AssetThumbnailView(asset: asset, source: source, side: side, isSelected: isSelected)
            .gesture(TapGesture(count: 2).onEnded { actions.open(asset.id) })
            // One tap gesture, dispatched on the modifiers held at the time: a plain TapGesture
            // also fires on modified clicks, so stacking modified variants would double up.
            .simultaneousGesture(TapGesture().onEnded { actions.click(asset.id, index) })
            .contextMenu { contextMenu }
            .modifier(PhotoDragSource(isEnabled: menu.albums != nil) { actions.targetIDs(asset) })
            .onAppear { actions.appear(index) }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open in Editor") { actions.open(asset.id) }
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
        lhs.asset == rhs.asset && lhs.index == rhs.index && lhs.side == rhs.side && lhs.isSelected == rhs.isSelected
            && lhs.menu == rhs.menu && lhs.identities == rhs.identities
    }
}

#Preview("Sample library") {
    @Previewable @State var selection: Set<LibraryAsset.ID> = ["sample-1", "sample-2"]
    AssetGridView(source: SampleLibrarySource(), selection: $selection) { _ in }
        .frame(width: 720, height: 500)
}

#Preview("Empty") {
    @Previewable @State var selection: Set<LibraryAsset.ID> = []
    AssetGridView(source: SampleLibrarySource(count: 0), selection: $selection) { _ in }
        .frame(width: 400, height: 300)
}
