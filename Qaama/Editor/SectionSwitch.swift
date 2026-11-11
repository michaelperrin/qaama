import SwiftUI

/// First row of an inspector section that can be switched off: the section's title and its switch.
/// The section itself has no header, the row stands for it.
struct SectionSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).fontWeight(.semibold)
        }
        .toggleStyle(.switch)
    }
}
