import EditModel
import EditorKit
import RenderEngine
import SwiftUI

/// The Crop & Straighten tab: shown while the canvas frames the image for cropping. The frame itself
/// is dragged on the canvas; this panel turns, straightens and constrains it.
struct CropInspector: View {
    let model: EditorModel
    /// Leaves the crop tool, applying the crop.
    let onDone: () -> Void

    var body: some View {
        Form {
            Section("Crop & Straighten") {
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
                LabeledContent("Rotate") {
                    HStack {
                        Button { model.rotate(quarterTurns: -1) } label: { Image(systemName: "rotate.left") }
                            .help("Rotate counterclockwise")
                        Button { model.rotate(quarterTurns: 1) } label: { Image(systemName: "rotate.right") }
                            .help("Rotate clockwise")
                    }
                }
                LabeledContent("Flip") {
                    Button { model.flipHorizontally() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        .help("Flip horizontally")
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
}
