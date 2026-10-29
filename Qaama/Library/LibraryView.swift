import LibraryKit
import SwiftUI

/// Apple Photos library grid: first building block of the proof of concept.
struct LibraryView: View {
    let source: PhotosLibrarySource
    @State private var selection: Selection?

    /// Identifiable wrapper so a sheet can be driven by the asset identifier alone.
    private struct Selection: Identifiable {
        let id: LibraryAsset.ID
    }

    private let thumbnailSide: CGFloat = 160

    var body: some View {
        Group {
            switch source.access {
            case .denied:
                accessDeniedView
            case .notDetermined:
                ProgressView("Requesting access to your photo library…")
            case .authorized, .limited:
                grid
            }
        }
        .task { await source.load() }
        .sheet(item: $selection) { selection in
            AssetDetailView(assetID: selection.id, source: source)
        }
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard !source.assets.isEmpty else { return "" }
        var text = "\(source.assets.count) photos"
        if let duration = source.lastLoadDuration {
            text += " · listed in \(duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))"
        }
        return text
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 8)], spacing: 8) {
                ForEach(source.assets) { asset in
                    AssetThumbnailView(asset: asset, source: source, side: thumbnailSide)
                        .onTapGesture { selection = Selection(id: asset.id) }
                }
            }
            .padding(12)
        }
        .overlay {
            if source.assets.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("Your photo library doesn't contain any images."))
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
