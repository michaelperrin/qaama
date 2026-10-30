import SwiftUI

/// One labelled slider of the inspector, with its value and a double-click reset.
struct AdjustmentSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    /// Called when a drag ends, so the owner can record one undo step per gesture.
    var onEditingEnded: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
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
                value = 0
                onEditingEnded()
            }
        }
    }
}
