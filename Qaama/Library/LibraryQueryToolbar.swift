import LibraryKit
import SwiftUI

/// Sort and filter controls for a library, as toolbar items. Controls the source doesn't support are hidden.
struct LibraryQueryToolbar: ToolbarContent {
    let source: any LibrarySource

    private var query: Binding<LibraryQuery> {
        Binding(get: { source.query }, set: { source.query = $0 })
    }

    private var supports: Set<QueryCapability> {
        source.queryCapabilities
    }

    var body: some ToolbarContent {
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
        ToolbarItem {
            Menu {
                if supports.contains(.rating) {
                    Picker("Rating", selection: query.minimumRating) {
                        Text("Any Rating").tag(0)
                        ForEach(1 ... 5, id: \.self) { stars in
                            Text("\(stars)+ Stars").tag(stars)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                }
                if supports.contains(.flag) {
                    Picker("Flag", selection: query.flag) {
                        Text("Any Flag").tag(LibraryQuery.FlagFilter.any)
                        Text("Picked").tag(LibraryQuery.FlagFilter.picked)
                        Text("Rejected").tag(LibraryQuery.FlagFilter.rejected)
                        Text("Unflagged").tag(LibraryQuery.FlagFilter.unflagged)
                        Text("Not Rejected").tag(LibraryQuery.FlagFilter.notRejected)
                    }
                    .pickerStyle(.inline)
                    Divider()
                }
                if supports.contains(.edited) {
                    Toggle("Edited Only", isOn: query.editedOnly)
                }
                if supports.contains(.raw) {
                    Toggle("RAW Only", isOn: query.rawOnly)
                }
                if supports.contains(.favorite) {
                    Toggle("Favorites Only", isOn: query.favoritesOnly)
                }
                if !source.query.isUnfiltered {
                    Divider()
                    Button("Clear Filters") {
                        var cleared = LibraryQuery()
                        cleared.sort = source.query.sort
                        cleared.ascending = source.query.ascending
                        source.query = cleared
                    }
                }
            } label: {
                Label("Filter", systemImage: source.query.isUnfiltered ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Filters")
        }
    }
}
