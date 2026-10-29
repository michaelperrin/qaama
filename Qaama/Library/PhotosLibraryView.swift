import LibraryKit
import SwiftUI

/// Apple Photos library: handles the access request, then shows the grid.
struct PhotosLibraryView: View {
    let source: PhotosLibrarySource

    var body: some View {
        Group {
            switch source.access {
            case .denied:
                accessDeniedView
            case .notDetermined:
                ProgressView("Requesting access to your photo library…")
            case .authorized, .limited:
                AssetGridView(source: source)
            }
        }
        .task { await source.load() }
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
