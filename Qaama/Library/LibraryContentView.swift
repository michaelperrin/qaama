import LibraryKit
import SwiftUI

/// Detail column of a library: the thumbnail grid, replaced by the editor while a photo is open.
struct LibraryContentView: View {
    let source: any LibrarySource
    @State private var editedAssetID: LibraryAsset.ID?
    @State private var selection: Set<LibraryAsset.ID> = []

    var body: some View {
        if let editedAssetID {
            EditorView(assetID: editedAssetID, source: source) { self.editedAssetID = nil }
                .id(editedAssetID)
                .navigationTitle(source.displayName)
                .navigationSubtitle("Editing")
        } else {
            AssetGridView(source: source, selection: $selection) { editedAssetID = $0 }
                .navigationTitle(source.displayName)
                .navigationSubtitle(subtitle)
                .toolbar { LibraryQueryToolbar(source: source) }
                .searchable(text: searchText, placement: .toolbar, prompt: "Search names and keywords")
                .searchSuggestions {}
        }
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
