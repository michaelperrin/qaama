import EditModel
import Foundation

/// Names a change to a recipe for the Edit menu ("Undo Exposure", "Undo Rotate Right"), from what
/// differs between the recipe before and after it.
///
/// Sliders, switches and canvas drags commit through `EditorModel.commitChange()` without saying
/// what they changed: reading it off the two recipes names every control, including those added
/// later, without each having to pass its own name. Operations whose intent the difference can't
/// tell (a preset, a paste, a reset) pass theirs to `commitChange(named:)` instead.
///
/// Settings are named as the inspector labels them, actions with a verb. A change that touches
/// several things at once gets the generic `several`.
nonisolated enum EditActionName {
    static let several = "Adjustments"

    static func describing(from old: EditRecipe, to new: EditRecipe) -> String {
        var names: [String] = []
        if old.retouches != new.retouches {
            names.append(retouchName(from: old.retouches, to: new.retouches))
        }
        if let name = geometryName(from: old.geometry ?? Geometry(), to: new.geometry ?? Geometry()) {
            names.append(name)
        }
        if old.layers != new.layers {
            names += layerNames(from: old.layers, to: new.layers)
        }
        return names.count == 1 ? names[0] : several
    }

    // MARK: - Retouches and geometry

    private static func retouchName(from old: [Retouch], to new: [Retouch]) -> String {
        if new.count == old.count + 1, new.starts(with: old) {
            return "Retouch"
        }
        return new.isEmpty ? "Remove Retouches" : "Retouches"
    }

    private static func geometryName(from old: Geometry, to new: Geometry) -> String? {
        guard old != new else { return nil }
        var names: [String] = []
        if old.quarterTurns != new.quarterTurns {
            switch (new.quarterTurns - old.quarterTurns + 4) % 4 {
            case 1: names.append("Rotate Right")
            case 3: names.append("Rotate Left")
            default: names.append("Rotate")
            }
        }
        if old.isFlippedHorizontally != new.isFlippedHorizontally {
            names.append("Flip Horizontal")
        }
        if old.angle != new.angle {
            names.append("Straighten")
        }
        // Choosing an aspect re-fits the crop to it: that is one change.
        if old.aspectRatio != new.aspectRatio {
            names.append("Aspect Ratio")
        } else if old.crop != new.crop {
            names.append("Crop")
        }
        return names.count == 1 ? names[0] : "Crop & Straighten"
    }

    // MARK: - Layers

    private static func layerNames(from old: [AdjustmentLayer], to new: [AdjustmentLayer]) -> [String] {
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        if newIDs.count == oldIDs.count + 1, let added = new.first(where: { !oldIDs.contains($0.id) }) {
            return [added.mask?.components.first.map { "Add \($0.kind.displayName) Mask" } ?? "Add Mask"]
        }
        if newIDs.count + 1 == oldIDs.count, oldIDs.filter(newIDs.contains) == newIDs {
            return ["Delete Mask"]
        }
        guard oldIDs == newIDs else { return [several] }
        return zip(old, new).flatMap { layerNames(from: $0, to: $1) }
    }

    private static func layerNames(from old: AdjustmentLayer, to new: AdjustmentLayer) -> [String] {
        var names: [String] = []
        if old.isEnabled != new.isEnabled {
            names.append(new.isEnabled ? "Turn On Mask" : "Turn Off Mask")
        }
        if old.mask != new.mask {
            names += maskNames(from: old.mask ?? Mask(), to: new.mask ?? Mask())
        }
        if old.adjustments != new.adjustments {
            names += adjustmentNames(from: old.adjustments, to: new.adjustments)
        }
        return names
    }

    private static func maskNames(from old: Mask, to new: Mask) -> [String] {
        var names: [String] = []
        if old.name != new.name {
            names.append("Rename Mask")
        }
        if old.isInverted != new.isInverted {
            names.append("Invert Mask")
        }
        if old.feather != new.feather {
            names.append("Mask Feather")
        }
        if old.density != new.density {
            names.append("Mask Density")
        }
        if old.components != new.components {
            names.append(componentName(from: old.components, to: new.components))
        }
        return names
    }

    private static func componentName(from old: [MaskComponent], to new: [MaskComponent]) -> String {
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        if newIDs.count == oldIDs.count + 1, let added = new.first(where: { !oldIDs.contains($0.id) }) {
            return combining(added)
        }
        if newIDs.count + 1 == oldIDs.count, let removed = old.first(where: { !newIDs.contains($0.id) }) {
            return "Remove \(removed.kind.displayName) from Mask"
        }
        let changed = zip(old, new).filter { $0 != $1 }
        guard oldIDs == newIDs, changed.count == 1, let (before, after) = changed.first else { return "Mask" }
        if before.operation != after.operation {
            return combining(after)
        }
        if case let .brush(previous) = before.kind, case let .brush(current) = after.kind,
           current.strokes.count == previous.strokes.count + 1, let stroke = current.strokes.last
        {
            return stroke.erases ? "Erase" : "Brush Stroke"
        }
        return after.kind.displayName
    }

    /// How a component takes part in its mask, as the layer menu's Add and Subtract put it.
    private static func combining(_ component: MaskComponent) -> String {
        let kind = component.kind.displayName
        return switch component.operation {
        case .add: "Add \(kind) to Mask"
        case .subtract: "Subtract \(kind) from Mask"
        case .intersect: "Intersect Mask with \(kind)"
        }
    }

    // MARK: - Adjustments

    private static func adjustmentNames(from old: AdjustmentSet, to new: AdjustmentSet) -> [String] {
        var names: [String] = []
        let values: [(KeyPath<AdjustmentSet, Double?>, String)] = [
            (\.temperature, "Temperature"), (\.tint, "Tint"), (\.exposure, "Exposure"), (\.highlights, "Highlights"),
            (\.shadows, "Shadows"), (\.blackPoint, "Black Point"), (\.contrast, "Contrast"), (\.vibrance, "Vibrance"),
            (\.saturation, "Saturation"), (\.sharpness, "Sharpness"), (\.noiseReduction, "Noise Reduction"),
            (\.dehaze, "Dehaze"), (\.grain, "Grain"),
        ]
        for (keyPath, name) in values where old[keyPath: keyPath] != new[keyPath: keyPath] {
            names.append(name)
        }
        for group in AdjustmentGroup.allCases where old.isEnabled(group) != new.isEnabled(group) {
            names.append(switched(new.isEnabled(group), groupName(group)))
        }
        if old.curves != new.curves {
            names.append(curvesName(from: old.curves ?? Curves(), to: new.curves ?? Curves()))
        }
        if old.hsl != new.hsl {
            names.append(colorMixerName(from: old.hsl ?? HSL(), to: new.hsl ?? HSL()))
        }
        if old.monochrome != new.monochrome {
            names += monochromeNames(from: old.monochrome ?? Monochrome(isEnabled: false), to: new.monochrome ?? Monochrome(isEnabled: false))
        }
        if old.lut != new.lut {
            names += lutNames(from: old.lut ?? LUT(isEnabled: false), to: new.lut ?? LUT(isEnabled: false))
        }
        if old.vignette != new.vignette {
            names += vignetteNames(from: old.vignette ?? Vignette(isEnabled: false), to: new.vignette ?? Vignette(isEnabled: false))
        }
        return names
    }

    private static func switched(_ isOn: Bool, _ name: String) -> String {
        (isOn ? "Turn On " : "Turn Off ") + name
    }

    /// The titles of the inspector's cards.
    private static func groupName(_ group: AdjustmentGroup) -> String {
        switch group {
        case .whiteBalance: "White Balance"
        case .light: "Light"
        case .curves: "Curves"
        case .color: "Color"
        case .colorMixer: "Color Mixer"
        case .detail: "Detail"
        case .effects: "Effects"
        }
    }

    private static func curvesName(from old: Curves, to new: Curves) -> String {
        let changed = Curves.Channel.allCases.filter { old[$0] != new[$0] }
        guard changed.count == 1 else { return "Curves" }
        return switch changed[0] {
        case .rgb: "RGB Curve"
        case .red: "Red Curve"
        case .green: "Green Curve"
        case .blue: "Blue Curve"
        }
    }

    private static func colorMixerName(from old: HSL, to new: HSL) -> String {
        var names: [String] = []
        for range in HSL.ColorRange.allCases where old[range] != new[range] {
            let color = range.rawValue.capitalized
            let before = old[range], after = new[range]
            if before.hue != after.hue {
                names.append("\(color) Hue")
            }
            if before.saturation != after.saturation {
                names.append("\(color) Saturation")
            }
            if before.luminance != after.luminance {
                names.append("\(color) Luminance")
            }
        }
        return names.count == 1 ? names[0] : "Color Mixer"
    }

    private static func monochromeNames(from old: Monochrome, to new: Monochrome) -> [String] {
        // Switching it on for the first time also brings its neutral mix: one change.
        if old.isEnabled != new.isEnabled {
            return [switched(new.isEnabled, "Black & White")]
        }
        let channels: [(KeyPath<Monochrome, Double>, String)] = [(\.red, "Red"), (\.green, "Green"), (\.blue, "Blue")]
        return channels.filter { old[keyPath: $0.0] != new[keyPath: $0.0] }.map { "Black & White \($0.1)" }
    }

    private static func lutNames(from old: LUT, to new: LUT) -> [String] {
        // Choosing a table also switches the LUT on: one change.
        if old.name != new.name {
            return [new.name == nil ? "Remove LUT" : "Apply LUT"]
        }
        var names: [String] = []
        if old.isEnabled != new.isEnabled {
            names.append(switched(new.isEnabled, "LUT"))
        }
        if old.intensity != new.intensity {
            names.append("LUT Intensity")
        }
        return names
    }

    private static func vignetteNames(from old: Vignette, to new: Vignette) -> [String] {
        // Switching it on for the first time also brings its default settings: one change.
        if old.isEnabled != new.isEnabled {
            return [switched(new.isEnabled, "Vignette")]
        }
        let settings: [(KeyPath<Vignette, Double>, String)] = [
            (\.amount, "Amount"), (\.midpoint, "Midpoint"), (\.feather, "Feather"), (\.roundness, "Roundness"),
            (\.highlights, "Highlights"),
        ]
        return settings.filter { old[keyPath: $0.0] != new[keyPath: $0.0] }.map { "Vignette \($0.1)" }
    }
}
