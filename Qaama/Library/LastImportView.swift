import LibraryKit
import SwiftUI

/// The detail column of "Last Import": the photos the last import brought, in the library they went
/// to, where they can be rated, filed in albums and edited like any others. Shown through a view of
/// that library that is the import's own, as a filter preset's is.
struct LastImportView: View {
    let record: ImportRecord
    let catalog: LibraryCatalog
    var maps: PhotoMapModels?

    var body: some View {
        Group {
            switch catalog.library(forLastImport: record) {
            case let .photos(source):
                PhotosLibraryView(source: source, albums: catalog.photosAlbums, albumEditor: catalog.photosAlbumEditor, maps: maps)
            case let .folder(view, scannedBy, _):
                FolderLibraryView(source: view, path: nil, maps: maps)
                    // The view only follows the catalog: the folder's own source lists and watches it.
                    .task { await scannedBy.load() }
                    // The files an import copied are known to the catalog once the folder is listed again.
                    .task(id: scannedBy.assets.count) { await catalog.refreshLastImport(record) }
            case nil:
                ContentUnavailableView("Library Unavailable", systemImage: "square.and.arrow.down",
                                       description: Text("The folder the photos were imported into is no longer in the sidebar."))
            }
        }
        .environment(\.libraryTitle, "Last Import")
    }
}
