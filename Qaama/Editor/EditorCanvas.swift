import EditorKit
import RenderEngine
import SwiftUI

/// The Metal preview, with a loading indicator until the original is decoded.
struct EditorCanvas: View {
    let model: EditorModel

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
            if !model.isOpen, model.statusMessage == nil {
                ProgressView("Opening original…").tint(.white).foregroundStyle(.white)
            }
        }
    }
}
