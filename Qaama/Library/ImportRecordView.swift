import LibraryKit
import SwiftUI

/// The detail column of an import of the sidebar: the photos it brought, in the library they went
/// to, where they can be rated, filed in albums and edited like any others. Shown through a view of
/// that library that is the import's own, as a filter preset's is.
struct ImportRecordView: View {
    let record: ImportRecord
    let catalog: LibraryCatalog
    var maps: PhotoMapModels?

    var body: some View {
        Group {
            switch catalog.library(forImport: record) {
            case let .photos(source):
                PhotosLibraryView(source: source, albums: catalog.photosAlbums, albumEditor: catalog.photosAlbumEditor, maps: maps)
            case let .folder(view, scannedBy, _):
                FolderLibraryView(source: view, path: nil, maps: maps)
                    // The view only follows the catalog: the folder's own source lists and watches it.
                    .task { await scannedBy.load() }
                    // The files an import copied are known to the catalog once the folder is listed again.
                    .task(id: scannedBy.assets.count) { await catalog.refreshImport(record) }
            case nil:
                ContentUnavailableView("Library Unavailable", systemImage: "square.and.arrow.down",
                                       description: Text("The folder the photos were imported into is no longer in the sidebar."))
            }
        }
        .environment(\.libraryTitle, record.title)
    }
}

extension ImportRecord {
    /// What the sidebar and the window call an import: the name it was given, else when it was made.
    var title: String {
        name ?? dateTitle
    }

    var dateTitle: String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "24 photos from “EOS_DIGITAL”", for the sidebar's help; with the date when the import
    /// shows under a name.
    var summary: String {
        let photos = "\(count == 1 ? "1 photo" : "\(count.formatted()) photos") from “\(deviceName)”"
        return name == nil ? photos : "\(photos), \(dateTitle)"
    }
}
