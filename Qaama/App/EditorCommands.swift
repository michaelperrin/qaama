import EditModel
import EditorKit
import LibraryKit
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

/// What File › Export… does in the key window: export the open photo, or the grid's selection.
struct ExportAction {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
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
    /// Nil where the library stores no rating: the menu is disabled.
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

/// File › New Album…, New Album Folder… and Export…, View › Show Inspector, and the Image menu:
/// Adjust Date & Time, Rating, Flag, the albums (Add to Album, Add to the last album, Remove from
/// Album) and Adjustments (copy, paste, create a preset). Act on the key window: its inspector
/// column, its export, its selection or open photo, its focused editor.
///
/// The 0 to 5, P, X and U keys belong to the Rating and Flag items, so they work in the grid and in
/// the editor alike, and nowhere else: a second holder of the same key would fire too. A key without
/// a modifier only reaches the menu when no text field took it.
struct EditorCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @FocusedValue(\.hasInspector) private var hasInspector
    @FocusedValue(\.adjustDateAction) private var adjustDateAction
    @FocusedValue(\.decisionsAction) private var decisions
    @FocusedValue(\.exportAction) private var exportAction
    @FocusedValue(\.albumsCommand) private var albumsCommand
    @FocusedValue(\.newAlbumAction) private var newAlbumAction
    @AppStorage(InspectorControls.visibilityKey) private var isInspectorVisible = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(isInspectorVisible ? "Hide Inspector" : "Show Inspector") { isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(hasInspector != true)
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
        }
        CommandMenu("Image") {
            Button("Adjust Date & Time…") { adjustDateAction?.run() }
                .disabled(adjustDateAction == nil)
            Divider()
            Menu("Rating") {
                ForEach(0 ... 5, id: \.self) { stars in
                    Toggle(Self.ratingTitle(stars), isOn: Binding(get: { decisions?.rating == stars }, set: { _ in decisions?.setRating?(stars) }))
                        .keyboardShortcut(KeyEquivalent(Character("\(stars)")), modifiers: [])
                    if stars == 0 {
                        Divider()
                    }
                }
            }
            .disabled(decisions?.setRating == nil)
            Menu("Flag") {
                // Choosing the flag in place again removes it, as clicking it does.
                Toggle("Pick", isOn: flagBinding(.picked))
                    .keyboardShortcut("p", modifiers: [])
                Toggle("Reject", isOn: flagBinding(.rejected))
                    .keyboardShortcut("x", modifiers: [])
                Divider()
                Button("Remove Flag") { decisions?.setFlag?(.none) }
                    .keyboardShortcut("u", modifiers: [])
            }
            .disabled(decisions?.setFlag == nil)
            Divider()
            AlbumMenuItems(albums: albumsCommand?.action, placement: .menuBar, targets: albumsCommand?.targets ?? { [] })
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

    private static func ratingTitle(_ stars: Int) -> String {
        switch stars {
        case 0: "No Rating"
        case 1: "1 Star"
        default: "\(stars) Stars"
        }
    }

    private func flagBinding(_ flag: ItemFlag) -> Binding<Bool> {
        Binding(get: { decisions?.flag == flag }, set: { _ in decisions?.setFlag?(decisions?.flag == flag ? .none : flag) })
    }
}
