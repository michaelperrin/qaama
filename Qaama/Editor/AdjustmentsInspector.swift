import EditModel
import EditorKit
import LibraryKit
import SwiftUI

/// The sliders of the global layer, grouped as the engine applies them: light, then color.
struct AdjustmentsInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        Form {
            Section {
                HistogramView(histogram: model.histogram)
                    .listRowInsets(EdgeInsets())
            }
            Section("White Balance") {
                slider("Temperature", \.temperature)
                slider("Tint", \.tint)
            }
            Section("Light") {
                slider("Exposure", \.exposure, unit: "EV")
                slider("Highlights", \.highlights)
                slider("Shadows", \.shadows)
                slider("Contrast", \.contrast)
            }
            Section("Color") {
                slider("Vibrance", \.vibrance)
                slider("Saturation", \.saturation)
            }
            Section("Info") {
                InfoPanel(model: model)
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

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<AdjustmentSet, Double?>, unit: String = "") -> some View {
        AdjustmentSlider(title: title, value: adjustment(keyPath), range: AdjustmentSet.range(of: keyPath), unit: unit,
                         onEditingEnded: model.commitChange)
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
