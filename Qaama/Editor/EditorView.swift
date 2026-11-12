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
    let onClose: () -> Void

    @State private var exportModel: ExportModel?
    @State private var presets = PresetStore()
    @State private var inspectorTab = InspectorTab.adjustments
    /// Hiding the inspector gives the whole window to the photo.
    @AppStorage(InspectorControls.visibilityKey) private var isInspectorVisible = true
    /// True once the column has been shown in this session: only then is the inspector worth building.
    @State private var inspectorWasShown = false
    /// The photo to move to once the user has decided what to do with unsaved changes.
    @State private var pendingNavigation: LibraryAsset.ID?
    @Environment(\.undoManager) private var undoManager

    private var model: EditorModel {
        session.model
    }

    /// True while the inspector has not caught up with the photo on the canvas.
    private var isInspectorBehind: Bool {
        session.settledModel !== model
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EditorCanvas(model: model)
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                // Hidden, the inspector stays alive at its full width, clipped out of view: removing
                // it would rebuild the whole adjustments form on the way back (150 ms measured).
                HStack(spacing: 0) {
                    Divider()
                    ZStack {
                        if inspectorWasShown, let inspectedModel = session.settledModel {
                            // Dimmed rather than disabled while it lags: disabling would redraw
                            // every control, the very cost the lag is there to avoid.
                            EditorInspector(model: inspectedModel, presets: presets, tab: $inspectorTab)
                                .opacity(isInspectorBehind ? 0.35 : 1)
                                .allowsHitTesting(!isInspectorBehind)
                        }
                        if isInspectorBehind {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: EditorInspector.width)
                    .frame(maxHeight: .infinity)
                }
                .frame(width: isInspectorVisible ? nil : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(isInspectorVisible)
                .accessibilityHidden(!isInspectorVisible)
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
                InspectorVisibilityButton(isVisible: $isInspectorVisible)
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
        .background(navigationShortcuts)
        .onChange(of: isInspectorVisible, initial: true) { _, isVisible in
            if isVisible {
                inspectorWasShown = true
            }
        }
        // Moving to another photo restarts this task, and with it the wait before the photo settles.
        .task(id: model.assetID) { await session.followCurrentPhoto() }
        .confirmationDialog("Save the changes to this photo?", isPresented: Binding(get: { pendingNavigation != nil }, set: {
            if !$0 {
                pendingNavigation = nil
            }
        }), titleVisibility: .visible, presenting: pendingNavigation) { destination in
            Button("Save") {
                let edited = model
                Task {
                    await edited.save()
                    if !edited.hasUnsavedChanges {
                        session.show(destination)
                    }
                }
            }
            Button("Discard Changes", role: .destructive) { session.show(destination) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Moving to another photo discards the edits you haven't saved.")
        }
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
            pendingNavigation = destination
        } else {
            session.show(destination)
        }
    }

    private func openExport() {
        guard let item = model.exportItem() else { return }
        exportModel = ExportModel(items: [item])
    }
}
