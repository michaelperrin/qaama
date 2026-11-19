import LibraryKit
import SwiftUI

/// One photo of a card or a camera as large as the window: what a double-click in the grid opens.
/// For looking only, to decide what to import; the arrow keys go from photo to photo, Escape and
/// the space bar go back to the grid.
///
/// The device gives no file to open: it is asked for an image at the size of the view, which takes
/// about as long as reading the file (measured: 0.4 to 0.8 s). The thumbnail embedded in the file
/// shows meanwhile, and the photos on either side are asked for in advance.
struct CameraPhotoViewer: View {
    let source: CameraLibrarySource
    /// Called with the photo on screen when the viewer closes.
    let onClose: (LibraryAsset.ID) -> Void

    /// The photo shown. A state, not a binding: the key handler of a held arrow key would keep
    /// reading a binding's first value (see AGENTS.md).
    @State private var assetID: LibraryAsset.ID
    @State private var image: CGImage?
    /// False while `image` is only the embedded thumbnail.
    @State private var isSharp = false
    @State private var viewSize = CGSize.zero
    @FocusState private var isFocused: Bool
    @Environment(\.displayScale) private var displayScale

    init(source: CameraLibrarySource, assetID: LibraryAsset.ID, onClose: @escaping (LibraryAsset.ID) -> Void) {
        self.source = source
        self.onClose = onClose
        _assetID = State(initialValue: assetID)
    }

    /// What the image on screen depends on: the photo, and the size it is asked at.
    private struct Request: Hashable {
        let assetID: LibraryAsset.ID
        let pixels: Int
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            }
            if !isSharp {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: .circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            step(press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(keys: [.escape, .space]) { _ in
            onClose(assetID)
            return .handled
        }
        .navigationTitle((assetID as NSString).lastPathComponent)
        .navigationSubtitle(subtitle)
        .toolbar {
            // As in the editor: back to the photos at the leading edge.
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { onClose(assetID) }
                    .help("Back to the photos")
            }
            ToolbarItem {
                ControlGroup {
                    Button("Previous", systemImage: "chevron.left") { step(-1) }
                        .disabled(source.neighbor(of: assetID, offset: -1) == nil)
                        .help("Previous photo")
                    Button("Next", systemImage: "chevron.right") { step(1) }
                        .disabled(source.neighbor(of: assetID, offset: 1) == nil)
                        .help("Next photo")
                }
            }
        }
        .task(id: Request(assetID: assetID, pixels: pixels)) { await load() }
    }

    /// The size to ask the device for; 0 until the view has one.
    private var pixels: Int {
        let longEdge = max(viewSize.width, viewSize.height) * displayScale
        return longEdge > 0 ? CameraLibrarySource.previewPixels(forLongEdge: longEdge) : 0
    }

    private var subtitle: String {
        let date = source.asset(id: assetID)?.creationDate?.formatted(date: .abbreviated, time: .shortened)
        let position = source.index(of: assetID).map { "\(($0 + 1).formatted()) of \(source.assets.count.formatted())" }
        return [date, position].compactMap(\.self).joined(separator: " · ")
    }

    private func step(_ offset: Int) {
        guard let next = source.neighbor(of: assetID, offset: offset) else { return }
        // Never the pixels of the photo just left under the name of the next one.
        image = nil
        isSharp = false
        assetID = next
    }

    private func load() async {
        guard pixels > 0, let asset = source.asset(id: assetID) else { return }
        // Usually in hand already, from the grid: it shows in the same update.
        if !isSharp, let quick = await source.quickThumbnail(for: asset), !Task.isCancelled {
            image = quick
        }
        guard let large = await source.preview(for: asset, maxPixelSize: pixels), !Task.isCancelled else { return }
        image = large
        isSharp = true
        // The photos on either side, the next one first, for the arrow keys to find them ready.
        for offset in [1, -1] {
            guard !Task.isCancelled, let neighbor = source.neighbor(of: assetID, offset: offset).flatMap({ source.asset(id: $0) }) else { continue }
            _ = await source.preview(for: neighbor, maxPixelSize: pixels)
        }
    }
}
