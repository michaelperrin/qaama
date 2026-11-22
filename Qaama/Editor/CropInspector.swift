import EditModel
import EditorKit
import RenderEngine
import SwiftUI

/// The Crop & Straighten tab: shown while the canvas frames the image for cropping. The frame itself
/// is dragged on the canvas; this panel turns, straightens and constrains it.
struct CropInspector: View {
    let model: EditorModel
    /// The user's own ratios, listed after the built-in ones.
    let ratios: CropRatioStore
    /// Leaves the crop tool, applying the crop.
    let onDone: () -> Void

    @State private var isAddingRatio = false
    @State private var newRatioText = ""
    @State private var newRatioName = ""
    /// What went wrong with the list of ratios, for the alert.
    @State private var ratioError: String?

    var body: some View {
        Form {
            Section("Crop & Straighten") {
                AdjustmentSlider(title: "Angle", value: angle, range: Geometry.angleRange, unit: "°", onEditingEnded: model.commitChange)
                LabeledContent("Aspect") { aspectMenu }
                LabeledContent("Rotate") {
                    HStack {
                        Button { model.apply(.rotateLeft) } label: { Image(systemName: "rotate.left") }
                            .help("Rotate left")
                        Button { model.apply(.rotateRight) } label: { Image(systemName: "rotate.right") }
                            .help("Rotate right")
                    }
                }
                LabeledContent("Flip") {
                    HStack {
                        Button { model.apply(.flipHorizontal) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                            .help("Flip horizontal")
                        Button { model.apply(.flipVertical) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                            .help("Flip vertical")
                    }
                }
            }
            Section {
                HStack {
                    Button("Reset") { model.resetGeometry() }
                        .disabled(model.geometry.isIdentity)
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .alert("New Aspect Ratio", isPresented: $isAddingRatio) {
            TextField("Width:Height", text: $newRatioText)
            TextField("Name (optional)", text: $newRatioName)
            Button("Add", action: addRatio)
                .disabled(CropRatio(parsing: newRatioText) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Width to height, such as 7:5 or 2.39:1. The ratio stays in the Aspect menu for every photo, under its name if you give it one.")
        }
        .alert("Couldn't Update Aspect Ratios", isPresented: Binding(get: { ratioError != nil }, set: {
            if !$0 {
                ratioError = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ratioError ?? "")
        }
    }

    /// A menu rather than a picker: under the ratios it holds the commands that edit their list.
    private var aspectMenu: some View {
        Menu {
            Picker("Aspect", selection: aspect) {
                Text("Free").tag(AspectChoice.free)
                Text("Original").tag(AspectChoice.original)
                Divider()
                ForEach(CropRatio.builtIn) { Text($0.name).tag(AspectChoice.fixed($0.value)) }
                if !ratios.ratios.isEmpty {
                    Divider()
                    ForEach(ratios.ratios) { Text($0.name).tag(AspectChoice.fixed($0.value)) }
                }
                // A crop locked to a ratio that is no longer listed keeps it, and shows it.
                if let unlisted = unlistedRatio {
                    Divider()
                    Text(CropRatio.name(forValue: unlisted)).tag(AspectChoice.fixed(unlisted))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Ratio…") {
                newRatioText = ""
                newRatioName = ""
                isAddingRatio = true
            }
            if !ratios.ratios.isEmpty {
                Menu("Remove Ratio") {
                    ForEach(ratios.ratios) { ratio in
                        Button(ratio.name) { remove(ratio) }
                    }
                }
            }
        } label: {
            Text(aspectName)
        }
        .controlSize(.small)
        .fixedSize()
    }

    /// What the menu's button reads: the ratio the crop is locked to.
    private var aspectName: String {
        switch aspect.wrappedValue {
        case .free: String(localized: "Free")
        case .original: String(localized: "Original")
        case let .fixed(value): ratios.listed(matching: value)?.name ?? CropRatio.name(forValue: value)
        }
    }

    /// The crop's ratio when it is neither the photo's own nor a listed one.
    private var unlistedRatio: Double? {
        guard case let .fixed(value) = aspect.wrappedValue, ratios.listed(matching: value) == nil else { return nil }
        return value
    }

    /// Locks the crop to the typed ratio and keeps it in the list. The crop doesn't depend on the
    /// list: it is locked even when the list couldn't be written.
    private func addRatio() {
        guard let typed = CropRatio(parsing: newRatioText, label: newRatioName) else {
            ratioError = String(localized: "“\(newRatioText)” isn't an aspect ratio. Type a width and a height, such as 7:5.")
            return
        }
        do {
            aspect.wrappedValue = try .fixed(ratios.add(typed).value)
        } catch {
            aspect.wrappedValue = .fixed(typed.value)
            ratioError = error.localizedDescription
        }
    }

    private func remove(_ ratio: CropRatio) {
        do {
            try ratios.remove(ratio)
        } catch {
            ratioError = error.localizedDescription
        }
    }

    private var angle: Binding<Double> {
        Binding(get: { model.geometry.angle }, set: { model.geometry.angle = $0 })
    }

    /// What the Aspect menu chooses; "Original" reads the image's own ratio from what the canvas
    /// shows, and a listed ratio is tagged with its exact value.
    private enum AspectChoice: Hashable {
        case free, original, fixed(Double)
    }

    private var aspect: Binding<AspectChoice> {
        Binding(
            get: {
                guard let ratio = model.geometry.aspectRatio else { return .free }
                if let extent = model.renderer?.image?.extent, extent.height > 0, abs(ratio - extent.width / extent.height) < CropRatio.tolerance {
                    return .original
                }
                return .fixed(ratios.listed(matching: ratio)?.value ?? ratio)
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
}
