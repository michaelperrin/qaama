import EditorKit
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Non-destructive editor: Metal canvas on the left, adjustments on the right. Shown in place of the
/// grid, not in a sheet: a Metal layer doesn't display inside macOS 27 sheets.
///
/// All behavior lives in `EditorSession` and its `EditorModel`; this view only lays out its parts.
///
/// The view lives as long as the session. Stepping to another photo with the arrow keys swaps the
/// session's model under it: the canvas, the toolbar, the bottom bar and the inspector stay in
/// place and show the new photo, nothing is rebuilt. Always read the model from the session.
///
/// The photo comes first. The inspector's form takes about 150 ms to build and 60 ms to refill with
/// another photo's values, so it shows the session's settled photo, a moment behind: it is built
/// only once a photo has stayed on screen, and only if the column is shown; after that it stays
/// alive, hidden or not, and while photos go by it keeps the last photo it showed, dimmed.
struct EditorView: View {
    let session: EditorSession
    /// Duplicate and Delete for the photo on screen, in the canvas's context menu; nil leaves them out.
    var filing: PhotoFilingAction?
    /// Takes the photo on screen out of the album it is looked at in; nil outside an album.
    var removeFromAlbum: (() -> Void)?
    let onClose: () -> Void

    @State private var exportModel: ExportModel?
    @State private var presets = PresetStore()
    @State private var luts = LUTStore()
    @State private var inspectorTab = InspectorTab.adjustments
    /// Hiding the inspector gives the whole window to the photo.
    @AppStorage(InspectorControls.visibilityKey) private var isInspectorVisible = true
    /// True once the column has been shown in this session: only then is the inspector worth building.
    @State private var inspectorWasShown = false
    /// The step to another photo waiting for the user to decide what to do with unsaved changes.
    @State private var pendingLeave: PendingLeave?
    @Environment(\.undoManager) private var undoManager
    /// Image › Location › Assign Location… opens the Info tab, where the place is chosen.
    @Environment(\.locationEditRequest) private var locationRequest

    private var model: EditorModel {
        session.model
    }

    /// True while the inspector has not caught up with the photo on the canvas.
    private var isInspectorBehind: Bool {
        session.settledModel !== model
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorCanvas(model: model)
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu { photoMenu }
                // The system's inspector, the same floating panel as next to the grid and the map:
                // the column doesn't change nature when a photo is opened. Around the canvas only,
                // so the bar below keeps the whole width for its controls. Hidden, the inspector
                // stays alive (checked: its views survive), so showing it again rebuilds nothing.
                .inspector(isPresented: $isInspectorVisible) {
                    ZStack {
                        if inspectorWasShown, let inspectedModel = session.settledModel {
                            // Dimmed rather than disabled while it lags: disabling would redraw
                            // every control, the very cost the lag is there to avoid.
                            EditorInspector(model: inspectedModel, presets: presets, luts: luts, tab: $inspectorTab)
                                .opacity(isInspectorBehind ? 0.35 : 1)
                                .allowsHitTesting(!isInspectorBehind)
                        }
                        if isInspectorBehind {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    // A fixed width: the adjustments form is laid out for it (see AGENTS.md on the wobble).
                    .inspectorColumnWidth(EditorInspector.width)
                }
            Divider()
            EditorBottomBar(model: model, onExport: openExport, onClose: onClose)
        }
        .toolbar {
            if let renderer = model.renderer {
                ToolbarItem {
                    CanvasZoomSlider(renderer: renderer)
                        .disabled(!model.isOpen)
                }
            }
            if isInspectorVisible {
                ToolbarItem(placement: .primaryAction) {
                    InspectorTabPicker(selection: $inspectorTab)
                        .disabled(!model.isOpen)
                }
            }
            // The inspector button stands alone at the far right, as in the grid.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                InspectorVisibilityToggle(isVisible: $isInspectorVisible)
            }
        }
        .modifier(InspectorControls(model: model, tab: $inspectorTab, isVisible: $isInspectorVisible))
        .presetNamingPrompt(model: model, presets: presets)
        .focusedSceneValue(\.editor, model)
        .focusedSceneValue(\.exportAction, model.canExport ? ExportAction(openExport) : nil)
        .focusedSceneValue(\.showInFinderAction, model.asset.flatMap(model.source.fileURL(for:)).map { url in
            ShowInFinderAction { FinderReveal.show([url]) }
        })
        .onChange(of: undoManager, initial: true) { _, manager in session.undoManager = manager }
        .onChange(of: locationRequest?.pending, initial: true) { _, pending in
            if pending != nil {
                inspectorTab = .info
            }
        }
        .background(navigationShortcuts)
        .onChange(of: isInspectorVisible, initial: true) { _, isVisible in
            if isVisible {
                inspectorWasShown = true
            }
        }
        // Moving to another photo restarts this task, and with it the wait before the photo settles.
        .task(id: model.assetID) { await session.followCurrentPhoto() }
        .unsavedChangesPrompt($pendingLeave)
        .onDisappear { session.close() }
        .sheet(isPresented: Binding(get: { exportModel != nil }, set: {
            if !$0 {
                exportModel = nil
            }
        })) {
            if let exportModel {
                ExportView(model: exportModel) { self.exportModel = nil }
            }
        }
    }

    /// The left and right arrow keys step through the library, in the grid's order. Text fields
    /// keep their arrows: an unmodified shortcut only fires when nothing else used the key.
    private var navigationShortcuts: some View {
        Group {
            Button("") { navigate(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { navigate(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    private func navigate(by offset: Int) {
        guard !model.isBusy, let destination = session.neighbor(offset: offset) else { return }
        if model.hasUnsavedChanges {
            pendingLeave = PendingLeave(model: model) { session.show(destination) }
        } else {
            session.show(destination)
        }
    }

    /// What can be done with the photo itself, on a secondary click: the items of the Image menu
    /// that the grid's context menu has too. Only what applies is listed.
    @ViewBuilder
    private var photoMenu: some View {
        if let removeFromAlbum {
            Button("Remove from Album", action: removeFromAlbum)
        }
        if let duplicate = filing?.duplicate {
            Button(PhotoFilingAction.duplicateTitle(count: 1), action: duplicate)
        }
        if let delete = filing?.delete {
            Divider()
            Button(PhotoFilingAction.deleteTitle(count: 1), role: .destructive, action: delete)
        }
    }

    private func openExport() {
        guard let item = model.exportItem() else { return }
        exportModel = ExportModel(items: [item])
    }
}
