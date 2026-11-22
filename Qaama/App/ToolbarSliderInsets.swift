import SwiftUI

extension View {
    /// Room on both sides of a slider standing in the toolbar. The toolbar draws its capsule on the
    /// item's bounds, and the capsule's ends are round: without it the knob or the icons at the ends
    /// of the slider sit in the curve.
    func toolbarSliderInsets() -> some View {
        padding(.horizontal, 14)
    }
}
