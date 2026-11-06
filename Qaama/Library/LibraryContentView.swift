import EditorKit
import LibraryKit
import SwiftUI

/// Detail column of a library: the thumbnail grid, replaced by the editor while a photo is open.
/// Both keep the window's inspector column on their right: the selected photo's Info panel next to
/// the grid, the editor's tabs next to the canvas.
struct LibraryContentView: View {
    let source: any LibrarySource
    /// The stay in the editor, from opening a photo to closing; it moves from photo to photo by itself.
    @State private var editorSession: EditorSession?
    @State private var selection: Set<LibraryAsset.ID> = []
    /// One setting for the grid and the editor, so the column stays put when a photo is opened.
    @AppStorage(InspectorControls.visibilityKey) private var isInspectorVisible = true

    var body: some View {
        content
            // View › Show Inspector acts on this window, grid or editor.
            .focusedSceneValue(\.hasInspector, true)
    }

    @ViewBuilder
    private var content: some View {
        if let editorSession {
            EditorView(session: editorSession) { closeEditor(editorSession) }
                .navigationTitle(source.displayName)
                .navigationSubtitle("Editing")
                .toolbar {
                    // Icon-only toolbar buttons get the system's round Liquid Glass bezel.
                    ToolbarItem(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") { closeEditor(editorSession) }
                            .help("Back to the photos")
                    }
                }
        } else {
            HStack(spacing: 0) {
                AssetGridView(source: source, selection: $selection) { editorSession = EditorSession(assetID: $0, source: source) }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let notice = source.indexingNotice {
                            IndexingNoticeView(notice: notice, progress: source.indexingProgress)
                        }
                    }
                    // Without it the row settles at the grid's ideal width, one column of thumbnails.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The Info form is light: unlike the editor's, it is simply rebuilt when shown again.
                if isInspectorVisible {
                    Divider()
                    LibraryInspector(source: source, selection: selection)
                        .frame(width: EditorInspector.width)
                }
            }
            .navigationTitle(source.displayName)
            .navigationSubtitle(subtitle)
            .toolbar {
                LibraryQueryToolbar(source: source)
                ToolbarItem(placement: .primaryAction) {
                    InspectorVisibilityButton(isVisible: $isInspectorVisible)
                }
            }
            .searchable(text: searchText, placement: .toolbar, prompt: "Search names and keywords")
            .searchSuggestions {}
        }
    }

    /// Returns to the grid, from the editor's Close button or the toolbar's Back button.
    private func closeEditor(_ session: EditorSession) {
        // Back in the grid, the photo last edited is the one selected.
        selection = [session.model.assetID]
        editorSession = nil
    }

    private var searchText: Binding<String> {
        Binding(get: { source.query.searchText }, set: { source.query.searchText = $0 })
    }

    private var subtitle: String {
        guard !source.assets.isEmpty else { return source.query.isUnfiltered ? "" : "No matches" }
        var text = source.query.isUnfiltered ? "\(source.assets.count) photos" : "\(source.assets.count) matching photos"
        if !selection.isEmpty {
            text += " · \(selection.count) selected"
        }
        if let duration = source.lastLoadDuration {
            text += " · listed in \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))"
        }
        if let progress = source.indexingProgress {
            text += " · indexing \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
        }
        return text
    }
}

#Preview("Grid then editor") {
    LibraryContentView(source: SampleLibrarySource())
        .frame(width: 900, height: 600)
}
