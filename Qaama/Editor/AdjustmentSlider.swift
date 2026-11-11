import SwiftUI

/// One labelled slider of the inspector, with its value and a double-click reset.
struct AdjustmentSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    /// What a double-click brings the slider back to.
    var resetValue: Double = 0
    /// Called when a drag ends, so the owner can record one undo step per gesture.
    var onEditingEnded: () -> Void = {}
    /// Text does not dim by itself in a disabled section (a vignette switched off), the slider does.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Slider(value: $value, in: range) { editing in
                if !editing {
                    onEditingEnded()
                }
            }
            .onTapGesture(count: 2) {
                value = resetValue
                onEditingEnded()
            }
        }
    }
}
