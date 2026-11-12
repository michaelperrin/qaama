import EditModel
import EditorKit
import RenderEngine
import SwiftUI

/// The controls of the Color Mixer: the hues of the photo as a small histogram, one swatch per
/// color range under it, and the hue, saturation and luminance of the range that is picked.
struct ColorMixerControls: View {
    @Bindable var model: EditorModel
    @State private var range = HSL.ColorRange.red

    var body: some View {
        VStack(spacing: 6) {
            HueHistogramView(histogram: model.hueHistogram)
            ColorRangePicker(selection: $range, edited: Set((model.adjustments.hsl?.values ?? [:]).keys))
        }
        SliderStack {
            slider("Hue", \.hue, gradient: SliderGradients.hue(of: range))
            slider("Saturation", \.saturation, gradient: SliderGradients.saturation(of: range))
            slider("Luminance", \.luminance, gradient: SliderGradients.luminance(of: range))
        }
        if model.adjustments.hsl != nil {
            Button("Reset Color Mixer") {
                model.adjustments.hsl = nil
                model.commitChange()
            }
        }
    }

    /// A slider on one component of the picked range; a mixer left with no value is stored as absent.
    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<HSLValue, Double>, gradient: Gradient) -> some View {
        let range = range
        let value = Binding(
            get: { (model.adjustments.hsl?[range] ?? HSLValue())[keyPath: keyPath] },
            set: { newValue in
                var hsl = model.adjustments.hsl ?? HSL()
                var value = hsl[range]
                value[keyPath: keyPath] = newValue
                hsl[range] = value
                model.adjustments.hsl = hsl.isIdentity ? nil : hsl
            }
        )
        return AdjustmentSlider(title: title, value: value, range: HSLValue.range, gradient: gradient, onEditingEnded: model.commitChange)
    }
}

/// The hues the color mixer receives, as bars in their own color, laid out so that the hues of
/// each color range stand above its swatch in `ColorRangePicker`.
struct HueHistogramView: View {
    let histogram: HueHistogram?
    @Environment(\.isEnabled) private var isEnabled

    private static let barsPerRange = 12
    /// Share of its slot a bar fills; the rest is the gap to the next one.
    private static let barFill: CGFloat = 0.6
    /// A line of every hue under the bars, so the place of a color shows even where the photo has none.
    private static let baselineHeight: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            let bars = histogram.bars(perRange: Self.barsPerRange)
            let step = size.width / CGFloat(bars.count)
            let room = size.height - Self.baselineHeight
            for (index, bar) in bars.enumerated() {
                let color = SliderGradients.color(hue: bar.hue, saturation: 0.85, brightness: 1)
                let x = (CGFloat(index) + (1 - Self.barFill) / 2) * step
                let baseline = CGRect(x: x, y: room, width: step * Self.barFill, height: Self.baselineHeight)
                context.fill(Path(baseline), with: .color(color.opacity(0.55)))
                if bar.height > 0 {
                    let height = max(1, room * CGFloat(bar.height))
                    context.fill(Path(CGRect(x: x, y: room - height, width: step * Self.barFill, height: height)), with: .color(color))
                }
            }
        }
        // The same side inset as the swatch strip, so the bars stand above their swatch.
        .padding(EdgeInsets(top: 6, leading: ColorRangePicker.inset, bottom: 4, trailing: ColorRangePicker.inset))
        .frame(height: 68)
        .background(.black.opacity(0.85))
        .clipShape(.rect(cornerRadius: 6))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel("Hues of the photo")
    }
}

/// One swatch per color range of the mixer in a segmented strip, the picked one on a raised cell.
/// A dot in a swatch marks a range that carries an adjustment: only one range shows its sliders at
/// a time.
struct ColorRangePicker: View {
    @Binding var selection: HSL.ColorRange
    let edited: Set<HSL.ColorRange>
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    /// Gap between the strip and its cells.
    static let inset: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HSL.ColorRange.allCases, id: \.self) { range in
                let name = LocalizedStringKey(range.rawValue.capitalized)
                Button {
                    selection = range
                } label: {
                    swatch(range)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selection == range {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.24) : .white)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(Text(name))
                .accessibilityValue(edited.contains(range) ? Text("Adjusted") : Text(""))
                .accessibilityAddTraits(selection == range ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .background(.primary.opacity(0.09), in: .rect(cornerRadius: 7))
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func swatch(_ range: HSL.ColorRange) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(SliderGradients.color(hue: range.hue))
            .frame(width: 16, height: 16)
            .overlay {
                if edited.contains(range) {
                    // White with a dark rim: it has to show on the yellow as on the blue.
                    Circle()
                        .fill(.white)
                        .strokeBorder(.black.opacity(0.35), lineWidth: 0.5)
                        .frame(width: 6, height: 6)
                }
            }
    }
}
