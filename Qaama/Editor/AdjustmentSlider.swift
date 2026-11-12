import SwiftUI

/// One labelled slider of the inspector, with its value and a double-click reset (on the track or
/// on the label).
struct AdjustmentSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    /// What a double-click brings the slider back to.
    var resetValue: Double = 0
    /// Painted on the track when the slider acts on color; see `SliderGradients`.
    var gradient: Gradient?
    /// Called when a drag ends, so the owner can record one undo step per gesture.
    var onEditingEnded: () -> Void = {}
    /// Text does not dim by itself in a disabled section (a vignette switched off).
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Spacer()
                // A value that was moved stands out from the ones left alone.
                Group {
                    Text(value, format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
                        .monospacedDigit()
                    if !unit.isEmpty {
                        Text(unit)
                    }
                }
                .foregroundStyle(isEnabled && value != resetValue ? .primary : .secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                value = resetValue
                onEditingEnded()
            }
            SliderTrack(value: $value, range: range, gradient: gradient, resetValue: resetValue, onEditingEnded: onEditingEnded)
        }
        // VoiceOver and keyboard users get the system slider the track stands for.
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { Text(title) }
        }
    }
}

/// The sliders of one inspector section, stacked in a single row of the Form: as rows of their own,
/// each would add the Form's padding and a separator, and the section would be half as tall again.
struct SliderStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) {
            content
        }
    }
}
