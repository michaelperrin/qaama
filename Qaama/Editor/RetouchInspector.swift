import EditModel
import EditorKit
import LibraryKit
import RenderEngine
import SwiftUI

/// The Retouch tab: shown while dragging on the canvas paints out what to remove. The painting
/// happens on the canvas (`RetouchOverlay`); this panel sets the brush and says what was done.
struct RetouchInspector: View {
    /// Preference holding the brush radius, as a fraction of the photo's long edge.
    static let radiusKey = "retouchBrushRadius"

    let model: EditorModel
    /// Leaves the retouch tool.
    let onDone: () -> Void

    /// The slider moves the radius by ratios: small brushes need the finer steps.
    private static let sliderRange = log2(Retouch.radiusRange.lowerBound) ... log2(Retouch.radiusRange.upperBound)

    var body: some View {
        Form {
            Section("Retouch") {
                Text("Paint over what you want to remove. It is filled in from its surroundings when you release.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text(diameter)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Slider(value: size, in: Self.sliderRange)
                }
                LabeledContent("Retouches") {
                    HStack(spacing: 6) {
                        if !model.pendingRetouches.isEmpty {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.recipe.retouches.count, format: .number)
                            .monospacedDigit()
                    }
                }
            }
            Section {
                HStack {
                    Button("Remove All") { model.removeRetouches() }
                        .disabled(model.recipe.retouches.isEmpty)
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            } footer: {
                Text("Pinch to zoom; hold Option and drag to move around. The [ and ] keys change the size.")
            }
        }
        .formStyle(.grouped)
    }

    private var size: Binding<Double> {
        Binding(get: { log2(model.retouchTool?.radius ?? 0.02) }, set: { model.setRetouchRadius(pow(2, $0)) })
    }

    /// The brush's diameter in pixels of the photo.
    private var diameter: String {
        guard let tool = model.retouchTool, let size = model.sourceImage?.pixelSize else { return "" }
        let pixels = Int((tool.radius * 2 * max(size.width, size.height)).rounded())
        return String(localized: "\(pixels) px")
    }
}

#Preview {
    RetouchInspector(model: EditorModel(assetID: "sample-1", source: SampleLibrarySource(), renderer: nil)) {}
        .frame(width: EditorInspector.width, height: 400)
}
