import EditModel
import EditorKit
import LibraryKit
import SwiftUI

/// The sliders of the global layer, grouped as the engine applies them: light, then color.
struct AdjustmentsInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        Form {
            Section("Light") {
                AdjustmentSlider(title: "Exposure", value: adjustment(\.exposure), range: AdjustmentSet.exposureRange, unit: "EV",
                                 onEditingEnded: model.commitChange)
                AdjustmentSlider(title: "Contrast", value: adjustment(\.contrast), range: AdjustmentSet.contrastRange,
                                 onEditingEnded: model.commitChange)
            }
            Section("Color") {
                AdjustmentSlider(title: "Saturation", value: adjustment(\.saturation), range: AdjustmentSet.saturationRange,
                                 onEditingEnded: model.commitChange)
            }
            Section {
                HStack {
                    // Through the window's undo manager when there is one, so the Edit menu stays in step.
                    Button("Undo") { model.undoManager?.undo() ?? model.undo() }
                        .disabled(!model.canUndo)
                    Button("Redo") { model.undoManager?.redo() ?? model.redo() }
                        .disabled(!model.canRedo)
                    Spacer()
                    Button("Reset") { model.reset() }
                        .disabled(model.recipe.isIdentity)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.isOpen)
    }

    /// Slider binding on an optional adjustment of the global layer: absent reads as neutral.
    private func adjustment(_ keyPath: WritableKeyPath<AdjustmentSet, Double?>) -> Binding<Double> {
        Binding(
            get: { model.recipe.global[keyPath: keyPath] ?? 0 },
            set: { model.recipe.global[keyPath: keyPath] = $0 == 0 ? nil : $0 }
        )
    }
}

#Preview {
    AdjustmentsInspector(model: EditorModel(assetID: "sample-1", source: SampleLibrarySource(), renderer: nil))
        .frame(width: 260, height: 400)
}
