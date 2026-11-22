import EditModel
import EditorKit
import LibraryKit
import RenderEngine
import SwiftUI

/// The editor shown in the key window, for the menu bar commands.
struct FocusedEditorKey: FocusedValueKey {
    typealias Value = EditorModel
}

extension FocusedValues {
    var editor: EditorModel? {
        get { self[FocusedEditorKey.self] }
        set { self[FocusedEditorKey.self] = newValue }
    }
}

/// True in a window that has the inspector column, next to the grid or in the editor, for
/// View › Show Inspector.
struct FocusedInspectorKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var hasInspector: Bool? {
        get { self[FocusedInspectorKey.self] }
        set { self[FocusedInspectorKey.self] = newValue }
    }
}

/// True in a window showing the thumbnail grid, for View › Zoom In, Zoom Out and the thumbnail shape.
struct FocusedAssetGridKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var hasAssetGrid: Bool? {
        get { self[FocusedAssetGridKey.self] }
        set { self[FocusedAssetGridKey.self] = newValue }
    }
}

/// True in a window showing a card or a camera, for View › Hide Already Imported.
struct FocusedImportedPhotosFilterKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var hasImportedPhotosFilter: Bool? {
        get { self[FocusedImportedPhotosFilterKey.self] }
        set { self[FocusedImportedPhotosFilterKey.self] = newValue }
    }
}

/// What File › Export… does in the key window: export the open photo, or the grid's selection.
struct ExportAction {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

/// What Image › Rotate and Flip do to the grid's selection; the editor's own photo goes through
/// its model.
struct GeometryChangeAction {
    let run: (GeometryChange) -> Void

    init(_ run: @escaping (GeometryChange) -> Void) {
        self.run = run
    }
}

/// The toolbar's quarter turn to the left, in the editor and above the grid: the one geometry
/// change worth a button, for photos that come in lying on their side. Image › Rotate Left is the
/// same command.
struct RotateLeftButton: View {
    let action: () -> Void

    var body: some View {
        Button("Rotate Left", systemImage: "rotate.left", action: action)
            .help("Rotate left (⌘L)")
    }
}

struct FocusedGeometryChangeKey: FocusedValueKey {
    typealias Value = GeometryChangeAction
}

extension FocusedValues {
    var geometryChangeAction: GeometryChangeAction? {
        get { self[FocusedGeometryChangeKey.self] }
        set { self[FocusedGeometryChangeKey.self] = newValue }
    }
}

struct FocusedExportKey: FocusedValueKey {
    typealias Value = ExportAction
}

extension FocusedValues {
    var exportAction: ExportAction? {
        get { self[FocusedExportKey.self] }
        set { self[FocusedExportKey.self] = newValue }
    }
}

/// What File › Show in Finder does in the key window: show the file of the open photo, or the files
/// of the grid's selection. Nil where the photos aren't files of a folder (Photos).
struct ShowInFinderAction {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

struct FocusedShowInFinderKey: FocusedValueKey {
    typealias Value = ShowInFinderAction
}

extension FocusedValues {
    var showInFinderAction: ShowInFinderAction? {
        get { self[FocusedShowInFinderKey.self] }
        set { self[FocusedShowInFinderKey.self] = newValue }
    }
}

/// What Image › Adjust Date & Time… does in the key window: open the dialog for the grid's selection,
/// or for the photo open in the editor.
struct AdjustDateAction {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

struct FocusedAdjustDateKey: FocusedValueKey {
    typealias Value = AdjustDateAction
}

extension FocusedValues {
    var adjustDateAction: AdjustDateAction? {
        get { self[FocusedAdjustDateKey.self] }
        set { self[FocusedAdjustDateKey.self] = newValue }
    }
}

/// What Image › Rating and Image › Flag act on in the key window: the photo open in the editor, or
/// the grid's selection.
struct DecisionsAction {
    /// The rating of the photo, or the one every selected photo has; nil when they differ or the
    /// selection is too large to tell. The menu checks it.
    let rating: Int?
    let flag: ItemFlag?
    /// Some photo has a rating, or a flag, for Remove Rating and Remove Flag; true when the selection
    /// is too large to tell.
    let hasRating: Bool
    let hasFlag: Bool
    /// Nil where the library stores no rating: the items are disabled.
    let setRating: ((Int) -> Void)?
    /// Nil where the library stores no flag (Photos).
    let setFlag: ((ItemFlag) -> Void)?
}

struct FocusedDecisionsKey: FocusedValueKey {
    typealias Value = DecisionsAction
}

extension FocusedValues {
    var decisionsAction: DecisionsAction? {
        get { self[FocusedDecisionsKey.self] }
        set { self[FocusedDecisionsKey.self] = newValue }
    }
}

/// What Image › Add to Album and its neighbors act on in the key window: the photo open in the
/// editor, or the grid's selection, looked up when an item is chosen.
struct AlbumsCommand {
    let action: AlbumsAction
    let targets: () -> [LibraryAsset.ID]
}

struct FocusedAlbumsKey: FocusedValueKey {
    typealias Value = AlbumsCommand
}

extension FocusedValues {
    var albumsCommand: AlbumsCommand? {
        get { self[FocusedAlbumsKey.self] }
        set { self[FocusedAlbumsKey.self] = newValue }
    }
}

struct FocusedPhotoFilingKey: FocusedValueKey {
    typealias Value = PhotoFilingAction
}

extension FocusedValues {
    /// Image › Duplicate and Image › Delete in the key window; see `PhotoFilingAction`.
    var photoFilingAction: PhotoFilingAction? {
        get { self[FocusedPhotoFilingKey.self] }
        set { self[FocusedPhotoFilingKey.self] = newValue }
    }
}

/// What File › New Album… and File › New Album Folder… do in the key window: ask for a name, then
/// create it at the top level of the Photos library's albums.
struct NewAlbumAction {
    let newAlbum: () -> Void
    let newFolder: () -> Void
}

struct FocusedNewAlbumKey: FocusedValueKey {
    typealias Value = NewAlbumAction
}

extension FocusedValues {
    var newAlbumAction: NewAlbumAction? {
        get { self[FocusedNewAlbumKey.self] }
        set { self[FocusedNewAlbumKey.self] = newValue }
    }
}

/// File › New Album…, New Album Folder…, Export… and Show in Finder, View › Show Inspector, Zoom In and Out (the
/// canvas of the open photo, else the grid), Zoom to Fit and Actual Size, the thumbnail shape (square
/// or whole photo), Go to Month, and the Image menu:
/// Adjust Date & Time, Rating and Flag (`DecisionMenuItems`), the albums (Add to Album, Add to the last album, Remove from
/// Album), Duplicate, Delete and Adjustments (copy, paste, create a preset). Act on the key window:
/// its inspector column, its export, its selection or open photo, its focused editor.
///
/// The 1 to 5, 0, P, X and U keys belong to the items of the Rating and Flag submenus, so they work
/// in the grid and in the editor alike, and nowhere else: a second holder of the same key would fire too. A key without
/// a modifier only reaches the menu when no text field took it. The same goes for the Delete key,
/// which Photos' conventions share between two items: it deletes the photos, except in an album,
/// where it takes them out of the album and deleting them is ⌘⌫.
///
/// Duplicate and Delete are in the Image menu, as in Photos, with the other things done to the
/// selected photos; File keeps what makes or sends out files (albums, Export, Show in Finder).
struct EditorCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @FocusedValue(\.hasInspector) private var hasInspector
    @FocusedValue(\.hasAssetGrid) private var hasAssetGrid
    @FocusedValue(\.hasImportedPhotosFilter) private var hasImportedPhotosFilter
    @FocusedValue(\.adjustDateAction) private var adjustDateAction
    @FocusedValue(\.decisionsAction) private var decisions
    @FocusedValue(\.locationAction) private var locationAction
    @FocusedValue(\.exportAction) private var exportAction
    @FocusedValue(\.geometryChangeAction) private var geometryChangeAction
    @FocusedValue(\.showInFinderAction) private var showInFinderAction
    @FocusedValue(\.albumsCommand) private var albumsCommand
    @FocusedValue(\.photoFilingAction) private var filing
    @FocusedValue(\.newAlbumAction) private var newAlbumAction
    @FocusedValue(\.goToMonthAction) private var goToMonthAction
    @FocusedValue(\.libraryDisplayAction) private var libraryDisplayAction
    @FocusedValue(\.mapZoomAction) private var mapZoomAction
    @FocusedValue(\.backAction) private var backAction
    @AppStorage(InspectorControls.visibilityKey) private var isInspectorVisible = true
    @AppStorage(GridDisplay.thumbnailSideKey) private var thumbnailSide = GridDisplay.defaultSide
    @AppStorage(GridDisplay.thumbnailFitKey) private var thumbnailFit = ThumbnailFit.fill
    /// The same preference as the toolbar button of a device's view.
    @AppStorage("importHidesImported") private var hidesImported = false
    @AppStorage(LibraryMapStyle.key) private var mapStyle = LibraryMapStyle.standard

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(isInspectorVisible ? "Hide Inspector" : "Show Inspector") { isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(hasInspector != true)
            Divider()
            // The canvas of the open photo, else the map, else the grid's thumbnails; the sliders in
            // the toolbar and the map's own buttons move the same settings.
            Button("Zoom In") {
                if let canvas {
                    canvas.setZoom(canvas.zoom * Self.canvasZoomStep)
                } else if let mapZoomAction {
                    mapZoomAction.zoomIn()
                } else {
                    thumbnailSide = GridDisplay.zoomedIn(thumbnailSide)
                }
            }
            .keyboardShortcut("+")
            .disabled(canvas.map { $0.zoom >= $0.zoomRange.upperBound }
                ?? mapZoomAction.map { _ in false }
                ?? (hasAssetGrid != true || thumbnailSide >= GridDisplay.sideRange.upperBound))
            Button("Zoom Out") {
                if let canvas {
                    canvas.setZoom(canvas.zoom / Self.canvasZoomStep)
                } else if let mapZoomAction {
                    mapZoomAction.zoomOut()
                } else {
                    thumbnailSide = GridDisplay.zoomedOut(thumbnailSide)
                }
            }
            .keyboardShortcut("-")
            .disabled(canvas.map { $0.zoom <= $0.zoomRange.lowerBound }
                ?? mapZoomAction.map { _ in false }
                ?? (hasAssetGrid != true || thumbnailSide <= GridDisplay.sideRange.lowerBound))
            Button("Zoom to Fit") {
                canvas?.setZoom(1)
                canvas?.panOffset = .zero
            }
            .keyboardShortcut("0")
            .disabled(canvas == nil)
            Button("Actual Size") {
                if let canvas, let actual = canvas.actualSizeZoom {
                    canvas.setZoom(actual)
                }
            }
            .keyboardShortcut("1")
            .disabled(canvas?.actualSizeZoom == nil)
            Divider()
            // As the Finder's "as Icons": the toolbar's switch makes the same choice.
            Picker("Show Photos", selection: Binding(get: { libraryDisplayAction?.current ?? .grid }, set: { libraryDisplayAction?.show($0) })) {
                Text("as Grid").tag(LibraryDisplay.grid)
                Text("as Map").tag(LibraryDisplay.map)
            }
            .pickerStyle(.inline)
            .disabled(libraryDisplayAction == nil)
            Picker("Map Style", selection: $mapStyle) {
                Text("Standard Map").tag(LibraryMapStyle.standard)
                Text("Satellite").tag(LibraryMapStyle.satellite)
            }
            .pickerStyle(.inline)
            // The map tells it is on screen by offering its zoom.
            .disabled(mapZoomAction == nil)
            Divider()
            Picker("Thumbnails", selection: $thumbnailFit) {
                Text("Square Thumbnails").tag(ThumbnailFit.fill)
                Text("Whole Photos").tag(ThumbnailFit.fit)
            }
            .pickerStyle(.inline)
            .disabled(hasAssetGrid != true)
            // The toolbar's filter button of a card or a camera, by its name.
            Toggle("Hide Already Imported", isOn: $hidesImported)
                .disabled(hasImportedPhotosFilter != true)
            Divider()
            // The toolbar's Back button, as the Finder's Go › Back.
            Button("Back") { backAction?.go() }
                .keyboardShortcut("[")
                .disabled(backAction == nil)
            // As Calendar's Go to Date…; the toolbar's month button opens the same picker.
            Button("Go to Month…") { goToMonthAction?.run() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(goToMonthAction == nil)
        }
        CommandGroup(after: .newItem) {
            // "Album Folder": a plain "Folder" here would read as a folder of photos on disk.
            Button("New Album…") { newAlbumAction?.newAlbum() }
                .disabled(newAlbumAction == nil)
            Button("New Album Folder…") { newAlbumAction?.newFolder() }
                .disabled(newAlbumAction == nil)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export…") { exportAction?.run() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(exportAction == nil)
            // ⇧⌘R, as in Music and Xcode.
            Button("Show in Finder") { showInFinderAction?.run() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(showInFinderAction == nil)
        }
        CommandMenu("Image") {
            Button("Adjust Date & Time…") { adjustDateAction?.run() }
                .disabled(adjustDateAction == nil)
            Menu("Location") {
                Button("Assign Location…") { locationAction?.assign?() }
                    .disabled(locationAction?.assign == nil)
                Button("Remove Location") { locationAction?.remove?() }
                    .disabled(locationAction?.remove == nil)
                Button("Revert to Original Location") { locationAction?.revert?() }
                    .disabled(locationAction?.revert == nil)
            }
            .disabled(locationAction == nil)
            Divider()
            DecisionMenuItems(placement: .menuBar, rating: decisions?.rating, flag: decisions?.flag,
                              hasRating: decisions?.hasRating ?? false, hasFlag: decisions?.hasFlag ?? false,
                              setRating: decisions?.setRating, setFlag: decisions?.setFlag)
            Divider()
            AlbumMenuItems(albums: albumsCommand?.action, placement: .menuBar, targets: albumsCommand?.targets ?? { [] })
            Divider()
            // ⌘D, as in the Finder and in Photos.
            Button(PhotoFilingAction.duplicateTitle(count: filing?.count ?? 1)) { filing?.duplicate?() }
                .keyboardShortcut("d")
                .disabled(filing?.duplicate == nil)
            // No ellipsis: the confirmation that follows asks for nothing more to go on.
            Button(PhotoFilingAction.deleteTitle(count: filing?.count ?? 1)) { filing?.delete?() }
                .keyboardShortcut(.delete, modifiers: albumsCommand?.action.remove == nil ? [] : [.command])
                .disabled(filing?.delete == nil)
            // Out of Recently Deleted, back in the library.
            Button(PhotoFilingAction.restoreTitle(count: filing?.count ?? 1)) { filing?.restore?() }
                .disabled(filing?.restore == nil)
            Divider()
            // ⌘L and ⌘R, as in Preview.
            Button("Rotate Left") { change(.rotateLeft) }
                .keyboardShortcut("l")
                .disabled(!canChangeGeometry)
            Button("Rotate Right") { change(.rotateRight) }
                .keyboardShortcut("r")
                .disabled(!canChangeGeometry)
            Button("Flip Horizontal") { change(.flipHorizontal) }
                .disabled(!canChangeGeometry)
            Button("Flip Vertical") { change(.flipVertical) }
                .disabled(!canChangeGeometry)
            Divider()
            Menu("Adjustments") {
                Button("Copy Adjustments") { editor?.copyAdjustments() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(editor?.isOpen != true)
                Button("Paste Adjustments") { editor?.pasteAdjustments() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(editor?.isOpen != true || AdjustmentsClipboard.shared.adjustments == nil)
                Divider()
                Button("Create Preset…") { editor?.requestPresetName() }
                    .disabled(editor?.isOpen != true || editor?.recipe.global.isIdentity != false)
            }
        }
    }

    /// The canvas of the photo open in the key window, for View › Zoom; nil in the grid.
    private var canvas: CanvasRenderer? {
        guard let editor, editor.isOpen else { return nil }
        return editor.renderer
    }

    /// The photo open in the key window, else the grid's selection.
    private var canChangeGeometry: Bool {
        editor.map(\.isOpen) ?? (geometryChangeAction != nil)
    }

    private func change(_ change: GeometryChange) {
        if let editor {
            editor.apply(change)
        } else {
            geometryChangeAction?.run(change)
        }
    }

    private static let canvasZoomStep: CGFloat = 1.25
}
