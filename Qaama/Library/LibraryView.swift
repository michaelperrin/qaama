import LibraryKit
import SwiftUI

/// Grille de la photothèque Apple : première brique du POC.
struct LibraryView: View {
    let source: PhotosLibrarySource
    @State private var selectedAsset: LibraryAsset?

    private let thumbnailSide: CGFloat = 160

    var body: some View {
        Group {
            switch source.access {
            case .denied:
                accessDeniedView
            case .notDetermined:
                ProgressView("Demande d'accès à la photothèque…")
            case .authorized, .limited:
                grid
            }
        }
        .task { await source.load(limit: 400) }
        .sheet(item: $selectedAsset) { asset in
            AssetDetailView(asset: asset, source: source)
        }
        .navigationTitle("Photothèque")
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 8)], spacing: 8) {
                ForEach(source.assets) { asset in
                    AssetThumbnailView(asset: asset, source: source, side: thumbnailSide)
                        .onTapGesture { selectedAsset = asset }
                }
            }
            .padding(12)
        }
        .overlay {
            if source.assets.isEmpty {
                ContentUnavailableView("Aucune photo", systemImage: "photo.on.rectangle",
                                       description: Text("La photothèque ne contient aucune image."))
            }
        }
    }

    private var accessDeniedView: some View {
        ContentUnavailableView {
            Label("Accès à la photothèque refusé", systemImage: "lock.fill")
        } description: {
            Text("Autorisez Qaama dans Réglages Système › Confidentialité et sécurité › Photos.")
        } actions: {
            Button("Ouvrir les Réglages Système") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
