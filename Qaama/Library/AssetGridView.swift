import EditorKit
import LibraryKit
import SwiftUI

/// Thumbnail grid shared by every library source. Tapping a photo reports its identifier.
struct AssetGridView: View {
    let source: any LibrarySource
    let onOpen: (LibraryAsset.ID) -> Void

    private let thumbnailSide: CGFloat = 160
    @State private var batchError: String?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSide), spacing: 8)], spacing: 8) {
                // Iterate indices, not elements: ForEach over elements walks the whole collection to compute
                // identities, which is far too slow for a lazily computed library of tens of thousands of rows.
                ForEach(source.assets.indices, id: \.self) { index in
                    let asset = source.assets[index]
                    AssetThumbnailView(asset: asset, source: source, side: thumbnailSide)
                        .onTapGesture { onOpen(asset.id) }
                        .contextMenu {
                            Button("Copy Adjustments") { run { try await BatchEditing.copyAdjustments(of: asset, from: source) } }
                                .disabled(!asset.hasEdit)
                            Button("Paste Adjustments") {
                                run { try await BatchEditing.pasteAdjustments(to: [asset], in: source, undoManager: undoManager) }
                            }
                            .disabled(AdjustmentsClipboard.shared.adjustments == nil)
                        }
                        .onAppear {
                            source.prefetchThumbnails(around: index, pixelSize: CGSize(width: thumbnailSide * displayScale, height: thumbnailSide * displayScale))
                        }
                }
            }
            .padding(12)
        }
        .alert("Adjustments", isPresented: Binding(get: { batchError != nil }, set: {
            if !$0 {
                batchError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(batchError ?? "")
        }
        .overlay {
            if source.assets.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("This library doesn't contain any images."))
            }
        }
    }
}

private extension AssetGridView {
    /// Runs a grid action and shows its error, if any.
    func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                batchError = error.localizedDescription
            }
        }
    }
}

#Preview("Sample library") {
    AssetGridView(source: SampleLibrarySource()) { _ in }
        .frame(width: 720, height: 500)
}

#Preview("Empty") {
    AssetGridView(source: SampleLibrarySource(count: 0)) { _ in }
        .frame(width: 400, height: 300)
}
