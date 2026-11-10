import EditorKit
import LibraryKit
import SwiftUI

/// The panels of the editor's right column, one per icon of its tab picker.
enum InspectorTab: String, CaseIterable, Identifiable {
    case info, crop, retouch, adjustments

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .crop: String(localized: "Crop & Straighten")
        case .retouch: String(localized: "Retouch")
        case .adjustments: String(localized: "Adjustments")
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .crop: "crop.rotate"
        case .retouch: "bandage"
        case .adjustments: "slider.horizontal.3"
        }
    }

    /// True for the tabs that are tools on the canvas: the photo is in that tool's mode while the
    /// tab is selected, and leaving the tool goes back to the tab the user was on.
    var isTool: Bool {
        self == .crop || self == .retouch
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
            case .retouch: RetouchInspector(model: model) { tab = restingTab }
            case .adjustments: AdjustmentsInspector(model: model, presets: presets)
            }
        }
        .disabled(!model.isOpen)
    }
}

/// What drives the inspector from outside the column: the C and R keys, and the link between the
/// tool tabs and the model's modes. Attached to the editor view rather than to the column, so all
/// of it keeps working while the column is hidden. The toolbar's tabs and show/hide button are laid
/// out by `EditorView` with the rest of its toolbar, so their order is in one place.
///
/// The Crop & Straighten tab is the crop tool: selecting it frames the image for cropping, leaving
/// it applies the crop. The Retouch tab is the retouch tool: while it is selected, dragging on the
/// canvas paints out what to remove. The model stays the source of truth for both modes, the tab
/// follows it.
struct InspectorControls: ViewModifier {
    static let restingTabKey = "editorInspectorTab"
    /// Whether the window's right column is shown; the grid's Info panel follows the same setting.
    static let visibilityKey = "editorInspectorVisible"

    let model: EditorModel
    @Binding var tab: InspectorTab
    @Binding var isVisible: Bool
    /// Where leaving a tool goes back to, and what the next photo opens on.
    @AppStorage(InspectorControls.restingTabKey) private var restingTab = InspectorTab.adjustments
    /// The retouch brush keeps its size from one photo and one launch to the next.
    @AppStorage(RetouchInspector.radiusKey) private var retouchRadius = 0.02

    func body(content: Content) -> some View {
        content
            .background(toolShortcuts)
            .onAppear { tab = restingTab.isTool ? .adjustments : restingTab }
            .onChange(of: tab) { _, new in
                if !new.isTool {
                    restingTab = new
                }
                // Each tool ends the other one when it begins.
                switch new {
                case .crop:
                    model.beginCropping()
                case .retouch:
                    model.beginRetouching(radius: retouchRadius)
                default:
                    model.endCropping()
                    model.endRetouching()
                }
            }
            .onChange(of: model.isRetouching) { _, isRetouching in
                // A new photo starts outside the tool, and the crop tool ends it.
                if isRetouching, tab != .retouch {
                    tab = .retouch
                } else if !isRetouching, tab == .retouch {
                    tab = restingTab
                }
            }
            .onChange(of: model.retouchTool?.radius) { _, radius in
                if let radius {
                    retouchRadius = radius
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

    /// The C and R keys toggle the crop and retouch tools from any tab, and with the column hidden.
    private var toolShortcuts: some View {
        Group {
            Button("") { tab = tab == .crop ? restingTab : .crop }
                .keyboardShortcut("c", modifiers: [])
            Button("") { tab = tab == .retouch ? restingTab : .retouch }
                .keyboardShortcut("r", modifiers: [])
        }
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
