import EditModel
import EditorKit
import SwiftUI

/// The layer list and the selected mask's controls. Every change goes through the model's recipe,
/// so it is undoable like any adjustment.
struct MasksSection: View {
    @Bindable var model: EditorModel
    @State private var renamingLayerID: UUID?
    @State private var newName = ""

    /// Kinds offered in the menus; sky and scene classes arrive with the segmentation model.
    static let availableKinds: [(title: LocalizedStringKey, kind: MaskKind)] = [
        ("Select Subject", .subject(instances: nil)),
        ("Select Background", .background),
        ("Select People", .people),
        ("Select Sky", .sky),
        ("Linear Gradient", .linearGradient(LinearGradientMask())),
        ("Radial Gradient", .radialGradient(RadialGradientMask())),
        ("Luminance Range", .luminosity(LuminosityRange(low: 0.5, high: 1, softness: 0.2))),
        ("Color Range", .color(ColorRange())),
    ]

    var body: some View {
        Section {
            layerRow(id: nil, name: "Whole Photo", isEnabled: nil)
            ForEach(model.recipe.maskedLayers) { layer in
                layerRow(id: layer.id, name: layer.mask?.displayName ?? "Layer", isEnabled: layer.isEnabled)
                    .contextMenu { layerMenu(layer) }
            }
            HStack {
                Menu("Add Mask") {
                    ForEach(Self.availableKinds.indices, id: \.self) { index in
                        Button(Self.availableKinds[index].title) { model.addMaskLayer(Self.availableKinds[index].kind) }
                    }
                    sceneMenu { model.addMaskLayer(.scene(classes: [$0])) }
                    Divider()
                    Button("Brush") { model.startBrush() }
                }
                .disabled(!model.isOpen)
                Spacer()
                if model.pendingMaskCount > 0 {
                    ProgressView().controlSize(.small).help("Computing masks…")
                }
                Toggle("Show Mask", isOn: $model.showsMaskOverlay)
                    .toggleStyle(.button)
                    .keyboardShortcut("o", modifiers: [])
                    .disabled(model.selectedLayer == nil)
            }
            .controlSize(.small)
            if let layer = model.selectedLayer, let mask = layer.mask {
                maskControls(layer: layer, mask: mask)
                if model.brushTool != nil {
                    brushControls
                }
            }
        } header: {
            Text("Masks")
        }
        .alert("Rename Mask", isPresented: Binding(get: { renamingLayerID != nil }, set: {
            if !$0 {
                renamingLayerID = nil
            }
        })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let id = renamingLayerID {
                    model.updateMask(id) { $0.name = newName.isEmpty ? nil : newName }
                    model.commitChange()
                }
                renamingLayerID = nil
            }
            Button("Cancel", role: .cancel) { renamingLayerID = nil }
        }
    }

    /// Scene classes the segmentation model can isolate.
    private func sceneMenu(_ action: @escaping (String) -> Void) -> some View {
        Menu("Scene") {
            ForEach(SceneClasses.all, id: \.label) { entry in
                Button(entry.displayName) { action(entry.label) }
            }
        }
    }

    // MARK: - Rows

    private func layerRow(id: UUID?, name: String, isEnabled: Bool?) -> some View {
        HStack {
            if let isEnabled, let id {
                Toggle("", isOn: Binding(get: { isEnabled }, set: { enabled in
                    model.updateLayer(id) { $0.isEnabled = enabled }
                    model.commitChange()
                }))
                .labelsHidden()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary).frame(width: 20)
            }
            Text(name)
            Spacer()
            if model.selectedLayerID == id {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
            if let id {
                Menu {
                    layerMenu(model.recipe.layers.first { $0.id == id }!)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedLayerID = id }
    }

    @ViewBuilder
    private func layerMenu(_ layer: AdjustmentLayer) -> some View {
        Menu("Add") {
            ForEach(Self.availableKinds.indices, id: \.self) { index in
                Button(Self.availableKinds[index].title) { model.addComponent(Self.availableKinds[index].kind, operation: .add, toLayer: layer.id) }
            }
            sceneMenu { model.addComponent(.scene(classes: [$0]), operation: .add, toLayer: layer.id) }
            Divider()
            Button("Brush") {
                model.selectedLayerID = layer.id
                model.startBrush(operation: .add)
            }
        }
        Menu("Subtract") {
            ForEach(Self.availableKinds.indices, id: \.self) { index in
                Button(Self.availableKinds[index].title) { model.addComponent(Self.availableKinds[index].kind, operation: .subtract, toLayer: layer.id) }
            }
            sceneMenu { model.addComponent(.scene(classes: [$0]), operation: .subtract, toLayer: layer.id) }
            Divider()
            Button("Brush") {
                model.selectedLayerID = layer.id
                model.startBrush(operation: .subtract)
            }
        }
        Divider()
        Button("Rename…") {
            newName = layer.mask?.name ?? ""
            renamingLayerID = layer.id
        }
        Button("Duplicate") { model.duplicateLayer(layer.id, inverted: false) }
        Button("Duplicate and Invert") { model.duplicateLayer(layer.id, inverted: true) }
        Button("Invert Mask") {
            model.updateMask(layer.id) { $0.isInverted.toggle() }
            model.commitChange()
        }
        Divider()
        Button("Delete", role: .destructive) { model.removeLayer(layer.id) }
    }

    // MARK: - Brush

    @ViewBuilder
    private var brushControls: some View {
        Divider()
        HStack {
            Label("Brush", systemImage: "paintbrush.pointed")
                .font(.callout.weight(.semibold))
            Spacer()
            Toggle("Erase", isOn: Binding(get: { model.brushTool?.erases ?? false }, set: { model.brushTool?.erases = $0 }))
                .toggleStyle(.button)
                .controlSize(.small)
            Button("Done") { model.brushTool = nil }
                .controlSize(.small)
        }
        AdjustmentSlider(title: "Size", value: Binding(get: { model.brushTool?.radius ?? 0.03 }, set: { model.brushTool?.radius = $0 }),
                         range: 0.002 ... 0.25)
        AdjustmentSlider(title: "Hardness", value: Binding(get: { model.brushTool?.hardness ?? 0.5 }, set: { model.brushTool?.hardness = $0 }),
                         range: 0 ... 1)
        // Keyboard: [ and ] change the size, E toggles erasing.
        Button("") { model.brushTool?.radius = max(0.002, (model.brushTool?.radius ?? 0.03) / 1.25) }.keyboardShortcut("[", modifiers: []).hidden()
        Button("") { model.brushTool?.radius = min(0.25, (model.brushTool?.radius ?? 0.03) * 1.25) }.keyboardShortcut("]", modifiers: []).hidden()
        Button("") { model.brushTool?.erases.toggle() }.keyboardShortcut("e", modifiers: []).hidden()
    }

    // MARK: - Selected mask

    @ViewBuilder
    private func maskControls(layer: AdjustmentLayer, mask: Mask) -> some View {
        ForEach(mask.components) { component in
            componentRow(component, layer: layer)
        }
        AdjustmentSlider(title: "Feather", value: maskValue(layer.id, \.feather), range: 0 ... 1, onEditingEnded: model.commitChange)
        AdjustmentSlider(title: "Density", value: maskValue(layer.id, \.density), range: 0 ... 1, onEditingEnded: model.commitChange)
        Toggle("Invert", isOn: Binding(get: { mask.isInverted }, set: { inverted in
            model.updateMask(layer.id) { $0.isInverted = inverted }
            model.commitChange()
        }))
    }

    @ViewBuilder
    private func componentRow(_ component: MaskComponent, layer: AdjustmentLayer) -> some View {
        HStack {
            Picker("", selection: Binding(get: { component.operation }, set: { operation in
                model.updateMask(layer.id) { mask in
                    if let index = mask.components.firstIndex(where: { $0.id == component.id }) {
                        mask.components[index].operation = operation
                    }
                }
                model.commitChange()
            })) {
                Text("Add").tag(MaskComponent.Operation.add)
                Text("Subtract").tag(MaskComponent.Operation.subtract)
                Text("Intersect").tag(MaskComponent.Operation.intersect)
            }
            .labelsHidden()
            .frame(width: 100)
            Text(component.kind.displayName).font(.callout)
            Spacer()
            Button {
                model.updateMask(layer.id) { $0.components.removeAll { $0.id == component.id } }
                model.commitChange()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .disabled(mask(of: layer).components.count <= 1)
        }
        .controlSize(.small)
        componentParameters(component, layer: layer)
    }

    @ViewBuilder
    private func componentParameters(_ component: MaskComponent, layer: AdjustmentLayer) -> some View {
        switch component.kind {
        case .luminosity:
            parameterSlider("Low", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .luminosity(r) = kind {
                    r.low
                } else {
                    0
                }
            } set: { kind, value in
                if case var .luminosity(r) = kind {
                    r = LuminosityRange(low: value, high: max(r.high, value), softness: r.softness); return .luminosity(r)
                }
                return kind
            }
            parameterSlider("High", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .luminosity(r) = kind {
                    r.high
                } else {
                    1
                }
            } set: { kind, value in
                if case var .luminosity(r) = kind {
                    r = LuminosityRange(low: min(r.low, value), high: value, softness: r.softness); return .luminosity(r)
                }
                return kind
            }
            parameterSlider("Softness", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .luminosity(r) = kind {
                    r.softness
                } else {
                    0
                }
            } set: { kind, value in
                if case var .luminosity(r) = kind {
                    r = LuminosityRange(low: r.low, high: r.high, softness: value); return .luminosity(r)
                }
                return kind
            }
        case .color:
            parameterSlider("Hue", layer: layer, component: component, range: 0 ... 360, unit: "°") { kind in
                if case let .color(r) = kind {
                    r.hue
                } else {
                    0
                }
            } set: { kind, value in
                if case var .color(r) = kind {
                    r = ColorRange(hue: value, hueRange: r.hueRange, saturationMinimum: r.saturationMinimum, softness: r.softness); return .color(r)
                }
                return kind
            }
            parameterSlider("Range", layer: layer, component: component, range: 1 ... 180, unit: "°") { kind in
                if case let .color(r) = kind {
                    r.hueRange
                } else {
                    30
                }
            } set: { kind, value in
                if case var .color(r) = kind {
                    r = ColorRange(hue: r.hue, hueRange: value, saturationMinimum: r.saturationMinimum, softness: r.softness); return .color(r)
                }
                return kind
            }
            parameterSlider("Min Saturation", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .color(r) = kind {
                    r.saturationMinimum
                } else {
                    0
                }
            } set: { kind, value in
                if case var .color(r) = kind {
                    r = ColorRange(hue: r.hue, hueRange: r.hueRange, saturationMinimum: value, softness: r.softness); return .color(r)
                }
                return kind
            }
        case .radialGradient:
            parameterSlider("Center X", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .radialGradient(g) = kind {
                    g.center.x
                } else {
                    0.5
                }
            } set: { kind, value in
                if case var .radialGradient(g) = kind {
                    g.center.x = value; return .radialGradient(g)
                }
                return kind
            }
            parameterSlider("Center Y", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .radialGradient(g) = kind {
                    g.center.y
                } else {
                    0.5
                }
            } set: { kind, value in
                if case var .radialGradient(g) = kind {
                    g.center.y = value; return .radialGradient(g)
                }
                return kind
            }
            parameterSlider("Width", layer: layer, component: component, range: 0.01 ... 1) { kind in
                if case let .radialGradient(g) = kind {
                    g.radiusX
                } else {
                    0.3
                }
            } set: { kind, value in
                if case var .radialGradient(g) = kind {
                    g.radiusX = value; return .radialGradient(g)
                }
                return kind
            }
            parameterSlider("Height", layer: layer, component: component, range: 0.01 ... 1) { kind in
                if case let .radialGradient(g) = kind {
                    g.radiusY
                } else {
                    0.2
                }
            } set: { kind, value in
                if case var .radialGradient(g) = kind {
                    g.radiusY = value; return .radialGradient(g)
                }
                return kind
            }
            parameterSlider("Softness", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .radialGradient(g) = kind {
                    g.softness
                } else {
                    0.5
                }
            } set: { kind, value in
                if case var .radialGradient(g) = kind {
                    g.softness = value; return .radialGradient(g)
                }
                return kind
            }
        case .linearGradient:
            parameterSlider("Start", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .linearGradient(g) = kind {
                    g.start.y
                } else {
                    0.2
                }
            } set: { kind, value in
                if case var .linearGradient(g) = kind {
                    g.start.y = value; return .linearGradient(g)
                }
                return kind
            }
            parameterSlider("End", layer: layer, component: component, range: 0 ... 1) { kind in
                if case let .linearGradient(g) = kind {
                    g.end.y
                } else {
                    0.6
                }
            } set: { kind, value in
                if case var .linearGradient(g) = kind {
                    g.end.y = value; return .linearGradient(g)
                }
                return kind
            }
        case let .brush(brush):
            HStack {
                Text("\(brush.strokes.count) strokes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.brushTool?.componentID == component.id ? "Painting…" : "Paint") {
                    model.selectedLayerID = layer.id
                    model.brushTool = EditorModel.BrushTool(componentID: component.id)
                    model.showsMaskOverlay = true
                }
                .controlSize(.small)
                .disabled(model.brushTool?.componentID == component.id)
            }
            .padding(.leading, 16)
        default:
            EmptyView()
        }
    }

    private func parameterSlider(_ title: LocalizedStringKey, layer: AdjustmentLayer, component: MaskComponent, range: ClosedRange<Double>,
                                 unit: String = "", get: @escaping (MaskKind) -> Double, set: @escaping (MaskKind, Double) -> MaskKind) -> some View
    {
        AdjustmentSlider(title: title, value: Binding(
            get: { get(currentKind(component, layer: layer)) },
            set: { value in
                model.updateMask(layer.id) { mask in
                    if let index = mask.components.firstIndex(where: { $0.id == component.id }) {
                        mask.components[index].kind = set(mask.components[index].kind, value)
                    }
                }
            }
        ), range: range, unit: unit, onEditingEnded: model.commitChange)
            .padding(.leading, 16)
    }

    private func currentKind(_ component: MaskComponent, layer: AdjustmentLayer) -> MaskKind {
        mask(of: layer).components.first { $0.id == component.id }?.kind ?? component.kind
    }

    private func mask(of layer: AdjustmentLayer) -> Mask {
        model.recipe.layers.first { $0.id == layer.id }?.mask ?? layer.mask ?? Mask()
    }

    private func maskValue(_ layerID: UUID, _ keyPath: WritableKeyPath<Mask, Double>) -> Binding<Double> {
        Binding(
            get: { model.recipe.layers.first { $0.id == layerID }?.mask?[keyPath: keyPath] ?? 0 },
            set: { value in model.updateMask(layerID) { $0[keyPath: keyPath] = value } }
        )
    }
}
