import EditModel
import EditorKit
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

/// File › Export…, View › Show Inspector, and the Image menu: Adjust Date & Time, and Adjustments
/// (copy, paste, create a preset). Act on the key window: its inspector column, its export, its
/// selection or open photo, its focused editor.
struct EditorCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @FocusedValue(\.hasInspector) private var hasInspector
    @FocusedValue(\.adjustDateAction) private var adjustDateAction
    @FocusedValue(\.exportAction) private var exportAction
    @AppStorage(InspectorControls.visibilityKey) private var isInspectorVisible = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(isInspectorVisible ? "Hide Inspector" : "Show Inspector") { isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(hasInspector != true)
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
}
