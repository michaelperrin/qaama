import EditorKit
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Non-destructive editor: Metal canvas on the left, adjustments on the right. Shown in place of the
/// grid, not in a sheet: a Metal layer doesn't display inside macOS 27 sheets.
///
/// All behavior lives in `EditorModel`; this view only lays out its parts.
struct EditorView: View {
    let onClose: () -> Void

    @State private var model: EditorModel
    @State private var exportModel: ExportModel?
    @Environment(\.undoManager) private var undoManager

    init(assetID: LibraryAsset.ID, source: any LibrarySource, onClose: @escaping () -> Void) {
        _model = State(initialValue: EditorModel(assetID: assetID, source: source))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                EditorCanvas(model: model)
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                AdjustmentsInspector(model: model)
                    .frame(width: AdjustmentsInspector.width)
            }
            Divider()
            EditorBottomBar(model: model, onExport: openExport, onClose: onClose)
        }
        .focusedSceneValue(\.editor, model)
        .focusedSceneValue(\.exportAction, model.canExport ? ExportAction(openExport) : nil)
        .onChange(of: undoManager, initial: true) { _, manager in model.undoManager = manager }
        .task { await model.open() }
        .onDisappear { model.close() }
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

    private func openExport() {
        guard let item = model.exportItem() else { return }
        exportModel = ExportModel(items: [item])
    }
}
