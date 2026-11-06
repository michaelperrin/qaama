import EditorKit
import LibraryKit
import SwiftUI

/// The panels of the editor's right column, one per icon of its tab picker.
enum InspectorTab: String, CaseIterable, Identifiable {
    case info, crop, adjustments

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .crop: String(localized: "Crop & Straighten")
        case .adjustments: String(localized: "Adjustments")
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .crop: "crop.rotate"
        case .adjustments: "slider.horizontal.3"
        }
    }
}

/// Right column of the editor: one panel at a time, chosen with the icon tabs of the window's toolbar.
struct EditorInspector: View {
    let model: EditorModel
    let presets: PresetStore
    @Binding var tab: InspectorTab
    @AppStorage(InspectorControls.restingTabKey) private var restingTab = InspectorTab.adjustments

    /// Width of the column; the editor lays it out at this exact width.
    static let width: CGFloat = 280

    var body: some View {
        // A real container, not a Group: a Group would hand its modifiers to each panel in turn.
        VStack(spacing: 0) {
            switch tab {
            case .info: InfoInspector(model: model)
            case .crop: CropInspector(model: model) { tab = restingTab }
            case .adjustments: AdjustmentsInspector(model: model, presets: presets)
            }
        }
        .disabled(!model.isOpen)
    }
}

/// What drives the inspector from outside the column: the toolbar's tabs and show/hide button, the
/// C key, and the link between the Crop & Straighten tab and the model's crop mode. Attached to the
/// editor view rather than to the column, so all of it keeps working while the column is hidden.
///
/// The Crop & Straighten tab is the crop tool: selecting it frames the image for cropping, leaving
/// it applies the crop. The model stays the source of truth for that mode, the tab follows it.
struct InspectorControls: ViewModifier {
    static let restingTabKey = "editorInspectorTab"
    /// Whether the window's right column is shown; the grid's Info panel follows the same setting.
    static let visibilityKey = "editorInspectorVisible"

    let model: EditorModel
    @Binding var tab: InspectorTab
    @Binding var isVisible: Bool
    /// Where leaving the crop tool goes back to, and what the next photo opens on.
    @AppStorage(InspectorControls.restingTabKey) private var restingTab = InspectorTab.adjustments

    func body(content: Content) -> some View {
        content
            .background(cropShortcut)
            .toolbar {
                if isVisible {
                    ToolbarItem(placement: .primaryAction) {
                        InspectorTabPicker(selection: $tab)
                            .disabled(!model.isOpen)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    InspectorVisibilityButton(isVisible: $isVisible)
                }
            }
            .onAppear { tab = restingTab == .crop ? .adjustments : restingTab }
            .onChange(of: tab) { _, new in
                if new == .crop {
                    model.beginCropping()
                } else {
                    restingTab = new
                    model.endCropping()
                }
            }
            .onChange(of: model.isCropping) { _, isCropping in
                // The model can enter or leave the crop tool on its own (undo, a future menu command).
                if isCropping, tab != .crop {
                    tab = .crop
                } else if !isCropping, tab == .crop {
                    tab = restingTab
                }
            }
    }

    /// The C key toggles the crop tool from any tab, and with the column hidden.
    private var cropShortcut: some View {
        Button("") { tab = tab == .crop ? restingTab : .crop }
            .keyboardShortcut("c", modifiers: [])
            .disabled(!model.isOpen)
            .hidden()
            .frame(width: 0, height: 0)
    }
}

/// The toolbar button that shows or hides the window's right column, in the editor and in the grid.
struct InspectorVisibilityButton: View {
    @Binding var isVisible: Bool

    var body: some View {
        Button { isVisible.toggle() } label: {
            Label(isVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
        }
        .help(isVisible ? "Hide the inspector" : "Show the inspector")
    }
}

/// Icon-only tabs, named by their tooltips; the labels' titles are what assistive technologies read.
struct InspectorTabPicker: View {
    @Binding var selection: InspectorTab

    var body: some View {
        Picker("Inspector", selection: $selection) {
            ForEach(InspectorTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .labelStyle(.iconOnly)
                    .help(tab.title)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }
}

#Preview {
    EditorInspector(model: EditorModel(assetID: "sample-1", source: SampleLibrarySource(), renderer: nil), presets: PresetStore(),
                    tab: .constant(.adjustments))
        .frame(width: EditorInspector.width, height: 500)
}
