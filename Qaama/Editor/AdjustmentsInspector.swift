import EditModel
import EditorKit
import LibraryKit
import RenderEngine
import SwiftUI

/// The Adjustments tab: histogram, presets, masks, then the sliders of the layer being edited,
/// grouped as the engine applies them: light, then color.
struct AdjustmentsInspector: View {
    @Bindable var model: EditorModel
    let presets: PresetStore
    @State private var hslComponent = HSLComponent.saturation

    enum HSLComponent: Hashable {
        case hue, saturation, luminance
    }

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
            MasksSection(model: model)
            Section {
                Label("Editing: \(model.editingTargetName)", systemImage: model.selectedLayerID == nil ? "photo" : "circle.lefthalf.filled")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(model.selectedLayerID == nil ? .secondary : Color.accentColor)
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
                if model.adjustments.hsl != nil {
                    Button("Reset Color Mixer") {
                        model.adjustments.hsl = nil
                        model.commitChange()
                    }
                }
            }
            Section("Detail") {
                slider("Sharpness", \.sharpness)
                slider("Noise Reduction", \.noiseReduction)
            }
            Section {
                SectionSwitch("Black & White", isOn: monochromeEnabled)
                if let monochrome = model.adjustments.monochrome {
                    AdjustmentSlider(title: "Red", value: mix(\.red, monochrome), range: Monochrome.range, onEditingEnded: model.commitChange)
                    AdjustmentSlider(title: "Green", value: mix(\.green, monochrome), range: Monochrome.range, onEditingEnded: model.commitChange)
                    AdjustmentSlider(title: "Blue", value: mix(\.blue, monochrome), range: Monochrome.range, onEditingEnded: model.commitChange)
                }
            }
            Section("Effects") {
                slider("Dehaze", \.dehaze)
                slider("Grain", \.grain)
            }
            Section {
                SectionSwitch("Vignette", isOn: vignetteEnabled)
                // The sliders stay in view when the vignette is off: its settings are kept.
                Group {
                    vignetteSlider("Amount", \.amount, range: Vignette.amountRange)
                    vignetteSlider("Midpoint", \.midpoint, range: Vignette.unitRange)
                    vignetteSlider("Feather", \.feather, range: Vignette.unitRange)
                    vignetteSlider("Roundness", \.roundness, range: Vignette.roundnessRange)
                    // Highlights only resist a darkening vignette.
                    vignetteSlider("Highlights", \.highlights, range: Vignette.unitRange)
                        .disabled((model.adjustments.vignette ?? Vignette()).amount >= 0)
                }
                .disabled(!vignetteEnabled.wrappedValue)
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
    }

    private func hslValue(_ range: HSL.ColorRange, _ component: HSLComponent) -> Binding<Double> {
        Binding(
            get: {
                let value = model.adjustments.hsl?[range] ?? HSLValue()
                switch component {
                case .hue: return value.hue
                case .saturation: return value.saturation
                case .luminance: return value.luminance
                }
            },
            set: { newValue in
                var hsl = model.adjustments.hsl ?? HSL()
                var value = hsl[range]
                switch component {
                case .hue: value.hue = newValue
                case .saturation: value.saturation = newValue
                case .luminance: value.luminance = newValue
                }
                hsl[range] = value
                model.adjustments.hsl = hsl.isIdentity ? nil : hsl
            }
        )
    }

    private func rangeColor(_ range: HSL.ColorRange) -> Color {
        Color(hue: range.hue / 360, saturation: 0.75, brightness: 0.9)
    }

    private var monochromeEnabled: Binding<Bool> {
        Binding(
            get: { model.adjustments.monochrome != nil },
            set: { enabled in
                model.adjustments.monochrome = enabled ? (model.adjustments.monochrome ?? Monochrome()) : nil
                model.commitChange()
            }
        )
    }

    private func mix(_ keyPath: WritableKeyPath<Monochrome, Double>, _ current: Monochrome) -> Binding<Double> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { value in
                var monochrome = model.adjustments.monochrome ?? Monochrome()
                monochrome[keyPath: keyPath] = value
                model.adjustments.monochrome = monochrome
            }
        )
    }

    /// Off until the vignette is first switched on, which gives it its default settings; switching it
    /// off afterwards keeps them.
    private var vignetteEnabled: Binding<Bool> {
        Binding(
            get: { model.adjustments.vignette?.isEnabled ?? false },
            set: { enabled in
                var vignette = model.adjustments.vignette ?? Vignette()
                vignette.isEnabled = enabled
                model.adjustments.vignette = vignette
                model.commitChange()
            }
        )
    }

    /// A slider on one setting of the vignette; a double-click brings back that setting's default.
    private func vignetteSlider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<Vignette, Double>,
                                range: ClosedRange<Double>) -> some View
    {
        let value = Binding(
            get: { (model.adjustments.vignette ?? Vignette())[keyPath: keyPath] },
            set: { newValue in
                var vignette = model.adjustments.vignette ?? Vignette()
                vignette[keyPath: keyPath] = newValue
                model.adjustments.vignette = vignette
            }
        )
        return AdjustmentSlider(title: title, value: value, range: range, resetValue: Vignette()[keyPath: keyPath],
                                onEditingEnded: model.commitChange)
    }

    /// Curves of the global layer; identity curves are stored as absent.
    private var curvesBinding: Binding<Curves> {
        Binding(
            get: { model.adjustments.curves ?? Curves() },
            set: { model.adjustments.curves = $0.isIdentity ? nil : $0 }
        )
    }

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<AdjustmentSet, Double?>, unit: String = "") -> some View {
        AdjustmentSlider(title: title, value: adjustment(keyPath), range: AdjustmentSet.range(of: keyPath), unit: unit,
                         onEditingEnded: model.commitChange)
    }

    /// Slider binding on an optional adjustment of the global layer: absent reads as neutral.
    private func adjustment(_ keyPath: WritableKeyPath<AdjustmentSet, Double?>) -> Binding<Double> {
        Binding(
            get: { model.adjustments[keyPath: keyPath] ?? 0 },
            set: { model.adjustments[keyPath: keyPath] = $0 == 0 ? nil : $0 }
        )
    }
}

/// Asks for a preset's name when the model requests one, from the inspector's button or the Image
/// menu. Attached to the whole column so it shows whichever tab is open.
private struct PresetNamingPrompt: ViewModifier {
    @Bindable var model: EditorModel
    let presets: PresetStore
    @State private var presetName = ""
    @State private var presetError: String?

    func body(content: Content) -> some View {
        content
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
}

extension View {
    func presetNamingPrompt(model: EditorModel, presets: PresetStore) -> some View {
        modifier(PresetNamingPrompt(model: model, presets: presets))
    }
}

#Preview {
    AdjustmentsInspector(model: EditorModel(assetID: "sample-1", source: SampleLibrarySource(), renderer: nil), presets: PresetStore())
        .frame(width: 260, height: 400)
}
