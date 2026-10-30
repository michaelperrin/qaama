import LibraryKit
import SwiftUI

/// Folder on disk: scans it on first display, then shows the grid.
struct FolderLibraryView: View {
    let source: FolderLibrarySource
    /// Subdirectory to show, or nil for the whole folder.
    var path: String?

    var body: some View {
        Group {
            if let error = source.loadError {
                ContentUnavailableView {
                    Label("Folder Unavailable", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { source.rescan() }
                }
            } else if !source.isLoaded {
                ProgressView("Scanning “\(source.displayName)”…")
            } else {
                LibraryContentView(source: source)
            }
        }
        .task { await source.load() }
        .onChange(of: path, initial: true) { _, new in source.query.folderPath = new }
    }
}
