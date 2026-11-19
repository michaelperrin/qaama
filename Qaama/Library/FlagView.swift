import LibraryKit
import SwiftUI

/// Pick / reject buttons. Clicking the current flag again clears it. The P, X and U keys are the
/// Image › Flag menu's. The flag set is told by its filled symbol in the text's color, not by green or
/// red, as with the stars of `RatingView`.
struct FlagView: View {
    let flag: ItemFlag
    let onChange: (ItemFlag) -> Void

    var body: some View {
        HStack(spacing: 4) {
            button(.picked, symbol: "checkmark.circle", help: "Pick (P)")
            button(.rejected, symbol: "xmark.circle", help: "Reject (X)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flag")
    }

    private func button(_ value: ItemFlag, symbol: String, help: LocalizedStringKey) -> some View {
        Button {
            set(value)
        } label: {
            Image(systemName: flag == value ? "\(symbol).fill" : symbol)
                .foregroundStyle(flag == value ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func set(_ value: ItemFlag) {
        onChange(flag == value ? .none : value)
    }
}

#Preview {
    @Previewable @State var flag = ItemFlag.picked
    FlagView(flag: flag) { flag = $0 }
        .padding()
}
