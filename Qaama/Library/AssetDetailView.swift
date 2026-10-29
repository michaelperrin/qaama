import LibraryKit
import SwiftUI

/// Full-size display of a photo with its rating. The real Metal canvas arrives with the rendering building block.
struct AssetDetailView: View {
    let assetID: LibraryAsset.ID
    let source: any LibrarySource

    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var errorMessage: String?

    /// Live copy of the asset, so the rating reflects library changes.
    private var asset: LibraryAsset? {
        source.assets.first { $0.id == assetID }
    }

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
            HStack(spacing: 16) {
                if let asset {
                    Text(asset.creationDate?.formatted(date: .long, time: .shortened) ?? "Unknown date")
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight) px")
                        .monospacedDigit()
                    Spacer()
                    if source.canRate {
                        RatingView(rating: asset.rating) { rate($0) }
                        ratingShortcuts
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 650)
        .task {
            if let asset {
                image = await source.fullSizeImage(for: asset)
            }
        }
    }

    /// Hidden buttons so the 0–5 keys set the rating, as in most photo browsers.
    private var ratingShortcuts: some View {
        ForEach(0 ... 5, id: \.self) { value in
            Button("") { rate(value) }
                .keyboardShortcut(KeyEquivalent(Character("\(value)")), modifiers: [])
                .hidden()
                .frame(width: 0, height: 0)
        }
    }

    private func rate(_ value: Int) {
        guard let asset else { return }
        Task {
            do {
                try await source.setRating(value, for: asset)
                errorMessage = nil
            } catch {
                errorMessage = "Rating failed: \(error.localizedDescription)"
            }
        }
    }
}
