import EditModel
import EditorKit
import LibraryKit
import RenderEngine
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
            Section("Crop & Straighten") {
                HStack {
                    Button(model.isCropping ? "Done" : "Crop") { model.toggleCropping() }
                        .keyboardShortcut("c", modifiers: [])
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { model.rotate(quarterTurns: -1) } label: { Image(systemName: "rotate.left") }
                        .help("Rotate counterclockwise")
                    Button { model.rotate(quarterTurns: 1) } label: { Image(systemName: "rotate.right") }
                        .help("Rotate clockwise")
                    Button { model.flipHorizontally() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .help("Flip horizontally")
                }
                AdjustmentSlider(title: "Angle", value: angle, range: Geometry.angleRange, unit: "°", onEditingEnded: model.commitChange)
                Picker("Aspect", selection: aspect) {
                    Text("Free").tag(AspectChoice.free)
                    Text("Original").tag(AspectChoice.original)
                    Text("Square").tag(AspectChoice.fixed(1))
                    Text("3:2").tag(AspectChoice.fixed(1.5))
                    Text("4:3").tag(AspectChoice.fixed(4 / 3))
                    Text("16:9").tag(AspectChoice.fixed(16 / 9))
                    Text("5:4").tag(AspectChoice.fixed(1.25))
                }
                if model.recipe.geometry != nil {
                    Button("Reset Crop & Straighten") { model.resetGeometry() }
                }
            }
            Section("White Balance") {
                slider("Temperature", \.temperature)
                slider("Tint", \.tint)
            }
            Section("Light") {
                slider("Exposure", \.exposure, unit: "EV")
                slider("Highlights", \.highlights)
                slider("Shadows", \.shadows)
                slider("Black Point", \.blackPoint)
                slider("Contrast", \.contrast)
            }
            Section("Color") {
                slider("Vibrance", \.vibrance)
                slider("Saturation", \.saturation)
            }
            Section("Detail") {
                slider("Sharpness", \.sharpness)
                slider("Noise Reduction", \.noiseReduction)
            }
            Section("Effects") {
                slider("Vignette", \.vignette)
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

    private var angle: Binding<Double> {
        Binding(get: { model.geometry.angle }, set: { model.geometry.angle = $0 })
    }

    /// Aspect presets; "Original" reads the image's own ratio from what the canvas shows.
    private enum AspectChoice: Hashable {
        case free, original, fixed(Double)
    }

    private var aspect: Binding<AspectChoice> {
        Binding(
            get: {
                guard let ratio = model.geometry.aspectRatio else { return .free }
                if let extent = model.renderer?.image?.extent, extent.height > 0, abs(ratio - extent.width / extent.height) < 0.001 {
                    return .original
                }
                return .fixed(ratio)
            },
            set: { choice in
                switch choice {
                case .free: model.geometry.aspectRatio = nil
                case let .fixed(ratio): model.geometry.aspectRatio = ratio
                case .original:
                    if let extent = model.renderer?.image?.extent, extent.height > 0 {
                        model.geometry.aspectRatio = extent.width / extent.height
                    }
                }
                applyAspectToCrop()
                model.commitChange()
            }
        )
    }

    /// Re-fits the crop to a newly chosen aspect, centered on the current crop.
    private func applyAspectToCrop() {
        guard let ratio = model.geometry.aspectRatio, let extent = model.renderer?.image?.extent, extent.height > 0 else { return }
        let imageAspect = extent.width / extent.height
        var crop = model.geometry.crop
        let unitAspect = ratio / imageAspect
        let center = (x: crop.x + crop.width / 2, y: crop.y + crop.height / 2)
        if crop.width / crop.height > unitAspect {
            crop.width = crop.height * unitAspect
        } else {
            crop.height = crop.width / unitAspect
        }
        crop.x = center.x - crop.width / 2
        crop.y = center.y - crop.height / 2
        model.geometry.crop = crop.clamped()
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
