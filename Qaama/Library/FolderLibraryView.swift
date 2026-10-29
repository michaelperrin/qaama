import LibraryKit
import SwiftUI

/// Folder on disk: scans it on first display, then shows the grid.
struct FolderLibraryView: View {
    let source: FolderLibrarySource

    var body: some View {
        Group {
            if let error = source.loadError {
                ContentUnavailableView {
                    Label("Folder Unavailable", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        source.invalidate()
                        Task { await source.load() }
                    }
                }
            } else if !source.isLoaded {
                ProgressView("Scanning “\(source.displayName)”…")
            } else {
                AssetGridView(source: source)
            }
        }
        .task { await source.load() }
    }
}
