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
            group("White Balance", .whiteBalance) {
                SliderStack {
                    slider("Temperature", \.temperature, gradient: SliderGradients.temperature)
                    slider("Tint", \.tint, gradient: SliderGradients.tint)
                }
            }
            group("Light", .light) {
                SliderStack {
                    slider("Exposure", \.exposure, unit: "EV")
                    slider("Highlights", \.highlights)
                    slider("Shadows", \.shadows)
                    slider("Black Point", \.blackPoint)
                    slider("Contrast", \.contrast)
                }
            }
            group("Curves", .curves) {
                CurveEditor(curves: curvesBinding, onEditingEnded: model.commitChange)
                    .opacity(model.adjustments.isEnabled(.curves) ? 1 : 0.5)
            }
            group("Color", .color) {
                SliderStack {
                    slider("Vibrance", \.vibrance, gradient: SliderGradients.vibrance)
                    slider("Saturation", \.saturation, gradient: SliderGradients.saturation)
                }
            }
            group("Color Mixer", .colorMixer) {
                ColorMixerControls(model: model)
            }
            group("Detail", .detail) {
                SliderStack {
                    slider("Sharpness", \.sharpness)
                    slider("Noise Reduction", \.noiseReduction)
                }
            }
            Section {
                SectionSwitch("Black & White", isOn: monochromeEnabled)
                // Hidden until black and white is first switched on; afterwards its mix stays in view.
                if let monochrome = model.adjustments.monochrome {
                    SliderStack {
                        mixSlider("Red", \.red, monochrome, hue: 0)
                        mixSlider("Green", \.green, monochrome, hue: 120)
                        mixSlider("Blue", \.blue, monochrome, hue: 240)
                    }
                    .disabled(!monochrome.isEnabled)
                }
            }
            group("Effects", .effects) {
                SliderStack {
                    slider("Dehaze", \.dehaze)
                    slider("Grain", \.grain)
                }
            }
            Section {
                SectionSwitch("Vignette", isOn: vignetteEnabled)
                // The sliders stay in view when the vignette is off: its settings are kept.
                SliderStack {
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

    /// One group of adjustments as a card: its title with the switch that turns the whole group off,
    /// then its controls, which stay in view when the group is off since their values are kept.
    private func group(_ title: LocalizedStringKey, _ group: AdjustmentGroup, @ViewBuilder content: () -> some View) -> some View {
        Section {
            SectionSwitch(title, isOn: Binding(
                get: { model.adjustments.isEnabled(group) },
                set: { isEnabled in
                    model.adjustments.setEnabled(isEnabled, for: group)
                    model.commitChange()
                }
            ))
            content()
                .disabled(!model.adjustments.isEnabled(group))
        }
    }

    /// Off until black and white is first switched on, with a neutral mix; switching it off
    /// afterwards keeps the mix.
    private var monochromeEnabled: Binding<Bool> {
        Binding(
            get: { model.adjustments.monochrome?.isEnabled ?? false },
            set: { enabled in
                var monochrome = model.adjustments.monochrome ?? Monochrome()
                monochrome.isEnabled = enabled
                model.adjustments.monochrome = monochrome
                model.commitChange()
            }
        )
    }

    /// A slider on one channel of the black and white mix, its track in that channel's color.
    private func mixSlider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<Monochrome, Double>, _ current: Monochrome,
                           hue: Double) -> some View
    {
        AdjustmentSlider(title: title, value: mix(keyPath, current), range: Monochrome.range, gradient: SliderGradients.tone(hue: hue),
                         onEditingEnded: model.commitChange)
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

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<AdjustmentSet, Double?>, unit: String = "",
                        gradient: Gradient? = nil) -> some View
    {
        AdjustmentSlider(title: title, value: adjustment(keyPath), range: AdjustmentSet.range(of: keyPath), unit: unit,
                         gradient: gradient, onEditingEnded: model.commitChange)
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
