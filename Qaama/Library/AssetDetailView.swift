import LibraryKit
import SwiftUI

/// Affichage pleine taille d'une photo. Le vrai canevas Metal viendra avec la brique rendu.
struct AssetDetailView: View {
    let asset: LibraryAsset
    let source: PhotosLibrarySource

    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            HStack {
                Text(asset.creationDate?.formatted(date: .long, time: .shortened) ?? "Date inconnue")
                Spacer()
                Text("\(asset.pixelWidth) × \(asset.pixelHeight) px")
                    .monospacedDigit()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 650)
        .task { image = await source.fullSizeImage(for: asset) }
    }
}
