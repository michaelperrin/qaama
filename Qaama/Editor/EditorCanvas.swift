import EditorKit
import RenderEngine
import SwiftUI

/// The Metal preview, with a loading indicator until the original is decoded.
struct EditorCanvas: View {
    let model: EditorModel
    /// True once the current photo has been loading for long enough to say so. The canvas keeps
    /// showing the previous photo meanwhile, and most photos open before the indicator is due.
    @State private var isSlowToOpen = false

    private static let loadingIndicatorDelay = Duration.milliseconds(300)

    var body: some View {
        ZStack {
            Color.black
            if let renderer = model.renderer {
                MetalCanvasView(renderer: renderer)
                    .disabled(model.isCropping || model.isEditingMask)
                if model.isCropping {
                    CropOverlay(model: model)
                } else if model.isEditingMask {
                    MaskOverlay(model: model)
                }
            } else {
                Text("Metal is not available on this Mac.").foregroundStyle(.white)
            }
            if isSlowToOpen, !model.isOpen, model.statusMessage == nil {
                ProgressView("Opening original…").tint(.white).foregroundStyle(.white)
            }
        }
        .task(id: model.assetID) {
            isSlowToOpen = false
            try? await Task.sleep(for: Self.loadingIndicatorDelay)
            isSlowToOpen = !Task.isCancelled
        }
    }
}
