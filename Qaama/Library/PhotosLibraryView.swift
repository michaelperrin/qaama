import LibraryKit
import SwiftUI

/// Apple Photos library: handles the access request, then shows the grid.
struct PhotosLibraryView: View {
    let source: PhotosLibrarySource
    /// Album list, loaded once access is granted; the sidebar shows it, the grid files photos in it.
    let albums: PhotosAlbumList
    let albumEditor: PhotosAlbumEditor
    var maps: PhotoMapModels?

    var body: some View {
        Group {
            switch source.access {
            case .denied:
                accessDeniedView
            case .notDetermined:
                ProgressView("Requesting access to your photo library…")
            case .authorized, .limited:
                // Photos can only be taken out of an album of the user's: Favorites is a smart album.
                LibraryContentView(source: source,
                                   albums: AlbumFiling(list: albums, editor: albumEditor, current: source.album?.kind == .user ? source.album : nil),
                                   maps: maps)
            }
        }
        .task {
            await source.load()
            if source.access == .authorized || source.access == .limited {
                albums.load()
            }
        }
    }

    private var accessDeniedView: some View {
        ContentUnavailableView {
            Label("Photo Library Access Denied", systemImage: "lock.fill")
        } description: {
            Text("Allow Qaama in System Settings › Privacy & Security › Photos.")
        } actions: {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
