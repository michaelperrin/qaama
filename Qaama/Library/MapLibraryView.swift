import LibraryKit
import SwiftUI

/// The map of every library together: the photos of the Photos library and of every folder, where
/// they were taken. There is no grid of them all; a double click on a group lists that group.
/// Photos asks for access here too when it wasn't asked yet; without it, the folders show alone.
struct MapLibraryView: View {
    let source: CombinedLibrarySource
    var maps: PhotoMapModels?

    var body: some View {
        Group {
            if source.isLoaded {
                LibraryContentView(source: source, maps: maps, showsOnlyMap: true)
            } else {
                ProgressView("Loading photos…")
            }
        }
        .task { await source.load() }
    }
}

#Preview {
    MapLibraryView(source: CombinedLibrarySource(displayName: "Map", members: [
        SampleLibrarySource(displayName: "A", idPrefix: "a"), SampleLibrarySource(displayName: "B", daysApart: 2, idPrefix: "b"),
    ]))
    .frame(width: 900, height: 600)
}
