import SwiftUI

/// A toolbar button that shows or hides one of the window's side columns and tells which it is by
/// its look: a button that behaves like a toggle, highlighted while the column is shown. The
/// sidebar's and the inspector's are the same control, so both sides of the window read alike.
struct ColumnVisibilityToggle: View {
    /// What the column is called: the toggle's label for assistive technologies, and its tooltip.
    let name: String
    let symbol: String
    @Binding var isVisible: Bool

    var body: some View {
        Toggle(isOn: $isVisible) {
            Label(name, systemImage: symbol)
        }
        .toggleStyle(.button)
        .help(isVisible ? "Hide the \(name.lowercased())" : "Show the \(name.lowercased())")
    }
}

/// The toggle of the window's right column, in the editor, next to the grid and next to the map.
struct InspectorVisibilityToggle: View {
    @Binding var isVisible: Bool

    var body: some View {
        ColumnVisibilityToggle(name: "Inspector", symbol: "sidebar.right", isVisible: $isVisible)
    }
}

/// The toggle of the sidebar. It replaces the system's, which doesn't show whether the sidebar is
/// there; View › Show Sidebar still works, and moves this toggle with it.
struct SidebarVisibilityToggle: View {
    @Binding var visibility: NavigationSplitViewVisibility

    var body: some View {
        ColumnVisibilityToggle(name: "Sidebar", symbol: "sidebar.left",
                               isVisible: Binding(get: { visibility != .detailOnly }, set: { visibility = $0 ? .all : .detailOnly }))
    }
}

#Preview {
    @Previewable @State var isVisible = true
    @Previewable @State var visibility = NavigationSplitViewVisibility.all
    HStack {
        SidebarVisibilityToggle(visibility: $visibility)
        InspectorVisibilityToggle(isVisible: $isVisible)
    }
    .padding()
}
