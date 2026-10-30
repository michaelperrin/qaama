import AppKit
import EditorKit
import LibraryKit
import SwiftUI

/// Thumbnail grid shared by every library source, with multiple selection: click selects, ⌘-click
/// toggles, ⇧-click extends from the last click, double-click opens the editor.
struct AssetGridView: View {
    let source: any LibrarySource
    @Binding var selection: Set<LibraryAsset.ID>
    let onOpen: (LibraryAsset.ID) -> Void

    private let thumbnailSide: CGFloat = 160
    /// Index of the last plain click, where a ⇧-click range starts.
    @State private var anchorIndex: Int?
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
                    AssetThumbnailView(asset: asset, source: source, side: thumbnailSide, isSelected: selection.contains(asset.id))
                        .gesture(TapGesture(count: 2).onEnded { onOpen(asset.id) })
                        // One tap gesture, dispatched on the modifiers held at the time: a plain TapGesture
                        // also fires on modified clicks, so stacking modified variants would double up.
                        .simultaneousGesture(TapGesture().onEnded { click(asset.id, at: index, modifiers: NSEvent.modifierFlags) })
                        .contextMenu { contextMenu(for: asset) }
                        .onAppear {
                            source.prefetchThumbnails(around: index, pixelSize: CGSize(width: thumbnailSide * displayScale, height: thumbnailSide * displayScale))
                        }
                }
            }
            .padding(12)
        }
        .background {
            // Keyboard: Escape clears the selection, ⌘A selects every photo shown.
            Button("") { selection.removeAll() }.keyboardShortcut(.cancelAction).hidden()
            Button("") { selection = Set(source.assets.map(\.id)) }.keyboardShortcut("a").hidden()
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

    // MARK: - Selection

    private func click(_ id: LibraryAsset.ID, at index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            toggle(id, at: index)
        } else if modifiers.contains(.shift) {
            extend(to: index)
        } else {
            select(id, at: index)
        }
    }

    private func select(_ id: LibraryAsset.ID, at index: Int) {
        selection = [id]
        anchorIndex = index
    }

    private func toggle(_ id: LibraryAsset.ID, at index: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
            anchorIndex = index
        }
    }

    private func extend(to index: Int) {
        let anchor = anchorIndex ?? index
        let range = min(anchor, index) ... max(anchor, index)
        let assets = source.assets
        selection.formUnion(range.compactMap { assets.indices.contains($0) ? assets[$0].id : nil })
    }

    /// The photos a context menu acts on: the whole selection when the clicked photo is part of it.
    private func targets(for asset: LibraryAsset) -> [LibraryAsset] {
        guard selection.contains(asset.id), selection.count > 1 else { return [asset] }
        return source.assets.filter { selection.contains($0.id) }
    }

    @ViewBuilder
    private func contextMenu(for asset: LibraryAsset) -> some View {
        let targets = targets(for: asset)
        Button("Open in Editor") { onOpen(asset.id) }
        Divider()
        Button("Copy Adjustments") { run { try await BatchEditing.copyAdjustments(of: asset, from: source) } }
            .disabled(!asset.hasEdit)
        Button(targets.count > 1 ? "Paste Adjustments to \(targets.count) Photos" : "Paste Adjustments") {
            run { try await BatchEditing.pasteAdjustments(to: targets, in: source, undoManager: undoManager) }
        }
        .disabled(AdjustmentsClipboard.shared.adjustments == nil)
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
    @Previewable @State var selection: Set<LibraryAsset.ID> = ["sample-1", "sample-2"]
    AssetGridView(source: SampleLibrarySource(), selection: $selection) { _ in }
        .frame(width: 720, height: 500)
}

#Preview("Empty") {
    @Previewable @State var selection: Set<LibraryAsset.ID> = []
    AssetGridView(source: SampleLibrarySource(count: 0), selection: $selection) { _ in }
        .frame(width: 400, height: 300)
}
