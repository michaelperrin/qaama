import EditModel
import EditorKit
import LibraryKit
import RenderEngine
import SwiftUI

/// The sliders of the global layer, grouped as the engine applies them: light, then color.
struct AdjustmentsInspector: View {
    @Bindable var model: EditorModel
    @State private var hslComponent = HSLComponent.saturation
    @State private var presets = PresetStore()
    @State private var presetName = ""
    @State private var presetError: String?

    enum HSLComponent: Hashable {
        case hue, saturation, luminance
    }

    /// Width of the inspector column; the editor lays it out at this exact width.
    static let width: CGFloat = 280

    var body: some View {
        Form {
            Section {
                HistogramView(histogram: model.histogram)
                    .listRowInsets(EdgeInsets())
            }
            Section("Presets") {
                HStack {
                    Menu("Apply Preset") {
                        if presets.presets.isEmpty {
                            Text("No presets yet")
                        }
                        ForEach(presets.presets) { preset in
                            Button(preset.name) { model.apply(preset) }
                        }
                        if !presets.presets.isEmpty {
                            Divider()
                            Menu("Delete Preset") {
                                ForEach(presets.presets) { preset in
                                    Button(preset.name, role: .destructive) { try? presets.delete(preset) }
                                }
                            }
                        }
                    }
                    .disabled(!model.isOpen)
                    Spacer()
                    Button("Save Preset…") { model.requestPresetName() }
                        .disabled(model.recipe.global.isIdentity)
                }
                HStack {
                    // Shortcuts live in the Image › Adjustments menu.
                    Button("Copy Adjustments") { model.copyAdjustments() }
                        .disabled(!model.isOpen)
                    Button("Paste Adjustments") { model.pasteAdjustments() }
                        .disabled(!model.isOpen || AdjustmentsClipboard.shared.adjustments == nil)
                }
                .controlSize(.small)
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
            Section("Curves") {
                CurveEditor(curves: curvesBinding, onEditingEnded: model.commitChange)
            }
            Section("Color") {
                slider("Vibrance", \.vibrance)
                slider("Saturation", \.saturation)
            }
            Section("Color Mixer") {
                // Short labels on purpose: a segmented control wider than the column makes the Form's
                // layout oscillate while a slider is dragged.
                Picker("Component", selection: $hslComponent) {
                    Text("Hue").tag(HSLComponent.hue)
                    Text("Sat").tag(HSLComponent.saturation)
                    Text("Lum").tag(HSLComponent.luminance)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                ForEach(HSL.ColorRange.allCases, id: \.self) { range in
                    AdjustmentSlider(title: LocalizedStringKey(range.rawValue.capitalized), value: hslValue(range, hslComponent),
                                     range: HSLValue.range, onEditingEnded: model.commitChange)
                        .tint(rangeColor(range))
                }
                if model.recipe.global.hsl != nil {
                    Button("Reset Color Mixer") {
                        model.recipe.global.hsl = nil
                        model.commitChange()
                    }
                }
            }
            Section("Detail") {
                slider("Sharpness", \.sharpness)
                slider("Noise Reduction", \.noiseReduction)
            }
            Section("Black & White") {
                Toggle("Black & White", isOn: monochromeEnabled)
                if let monochrome = model.recipe.global.monochrome {
                    AdjustmentSlider(title: "Red", value: mix(\.red, monochrome), range: Monochrome.range, onEditingEnded: model.commitChange)
                    AdjustmentSlider(title: "Green", value: mix(\.green, monochrome), range: Monochrome.range, onEditingEnded: model.commitChange)
                    AdjustmentSlider(title: "Blue", value: mix(\.blue, monochrome), range: Monochrome.range, onEditingEnded: model.commitChange)
                }
            }
            Section("Effects") {
                slider("Vignette", \.vignette)
                slider("Grain", \.grain)
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
        .alert("Save Preset", isPresented: $model.isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                do {
                    try presets.save(model.recipe.global, named: presetName)
                    presetName = ""
                } catch {
                    presetError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current adjustments will be saved under this name. Crop and straighten are not part of a preset.")
        }
        .alert("Couldn't Save Preset", isPresented: Binding(get: { presetError != nil }, set: {
            if !$0 {
                presetError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presetError ?? "")
        }
    }

    private func hslValue(_ range: HSL.ColorRange, _ component: HSLComponent) -> Binding<Double> {
        Binding(
            get: {
                let value = model.recipe.global.hsl?[range] ?? HSLValue()
                switch component {
                case .hue: return value.hue
                case .saturation: return value.saturation
                case .luminance: return value.luminance
                }
            },
            set: { newValue in
                var hsl = model.recipe.global.hsl ?? HSL()
                var value = hsl[range]
                switch component {
                case .hue: value.hue = newValue
                case .saturation: value.saturation = newValue
                case .luminance: value.luminance = newValue
                }
                hsl[range] = value
                model.recipe.global.hsl = hsl.isIdentity ? nil : hsl
            }
        )
    }

    private func rangeColor(_ range: HSL.ColorRange) -> Color {
        Color(hue: range.hue / 360, saturation: 0.75, brightness: 0.9)
    }

    private var monochromeEnabled: Binding<Bool> {
        Binding(
            get: { model.recipe.global.monochrome != nil },
            set: { enabled in
                model.recipe.global.monochrome = enabled ? (model.recipe.global.monochrome ?? Monochrome()) : nil
                model.commitChange()
            }
        )
    }

    private func mix(_ keyPath: WritableKeyPath<Monochrome, Double>, _ current: Monochrome) -> Binding<Double> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { value in
                var monochrome = model.recipe.global.monochrome ?? Monochrome()
                monochrome[keyPath: keyPath] = value
                model.recipe.global.monochrome = monochrome
            }
        )
    }

    /// Curves of the global layer; identity curves are stored as absent.
    private var curvesBinding: Binding<Curves> {
        Binding(
            get: { model.recipe.global.curves ?? Curves() },
            set: { model.recipe.global.curves = $0.isIdentity ? nil : $0 }
        )
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
