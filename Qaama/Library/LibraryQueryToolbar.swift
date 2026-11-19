import LibraryKit
import SwiftUI

/// Sort and filter controls for a library, as toolbar items: the Sort menu and the button of the
/// Filter panel. Controls the source doesn't support are hidden.
struct LibraryQueryToolbar: ToolbarContent {
    let source: any LibrarySource
    /// What the Filter panel of each library shows.
    let panels: LibraryFilterPanels
    /// Saving the Filter panel's settings as a preset; nil where presets can't be saved.
    var presets: FilterPresetSaving?
    /// False next to the map, where the order of the photos shows nowhere.
    var showsSort = true

    private var query: Binding<LibraryQuery> {
        Binding(get: { source.query }, set: { source.query = $0 })
    }

    private var supports: Set<QueryCapability> {
        source.queryCapabilities
    }

    var body: some ToolbarContent {
        if showsSort {
            ToolbarItem {
                Menu {
                    Picker("Sort by", selection: query.sort) {
                        Text("Capture Date").tag(LibraryQuery.Sort.captureDate)
                        Text("Modification Date").tag(LibraryQuery.Sort.modificationDate)
                        if supports.contains(.sortByRating) {
                            Text("Rating").tag(LibraryQuery.Sort.rating)
                        }
                        if supports.contains(.sortByFileName) {
                            Text("File Name").tag(LibraryQuery.Sort.fileName)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Ascending", isOn: query.ascending)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort order")
            }
        }
        ToolbarItem {
            FilterButton(source: source, panels: panels, presets: presets)
        }
    }
}
