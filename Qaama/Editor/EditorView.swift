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
    @State private var exportDocument: JPEGDocument?
    @State private var isExporting = false
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
            EditorBottomBar(model: model, onExport: exportJPEG, onClose: onClose)
        }
        .focusedSceneValue(\.editor, model)
        .onChange(of: undoManager, initial: true) { _, manager in model.undoManager = manager }
        .task { await model.open() }
        .onDisappear { model.close() }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .jpeg,
                      defaultFilename: "\(model.baseName) edited")
        { result in
            if case let .failure(error) = result {
                // The model owns the status line; an export failure is the only error raised by the view.
                exportError = error.localizedDescription
            }
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: {
            if !$0 {
                exportError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    @State private var exportError: String?

    private func exportJPEG() {
        Task {
            if let data = await model.exportJPEG() {
                exportDocument = JPEGDocument(data: data)
                isExporting = true
            }
        }
    }
}
