import EditorKit
import LibraryKit
import SwiftUI

/// Detail column of a library: the thumbnail grid, replaced by the editor while a photo is open.
struct LibraryContentView: View {
    let source: any LibrarySource
    /// The stay in the editor, from opening a photo to closing; it moves from photo to photo by itself.
    @State private var editorSession: EditorSession?
    @State private var selection: Set<LibraryAsset.ID> = []

    var body: some View {
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
            AssetGridView(source: source, selection: $selection) { editorSession = EditorSession(assetID: $0, source: source) }
                .navigationTitle(source.displayName)
                .navigationSubtitle(subtitle)
                .toolbar { LibraryQueryToolbar(source: source) }
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
        return text
    }
}

#Preview("Grid then editor") {
    LibraryContentView(source: SampleLibrarySource())
        .frame(width: 900, height: 600)
}
