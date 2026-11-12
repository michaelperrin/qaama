import EditorKit
import ImageIOKit
import SwiftUI

/// What the files say about themselves: camera settings, dimensions and date, as read from their
/// headers, for one photo or for what several share. Lines nothing is known for are left out.
/// Shared by the editor's Info tab and the grid's Info panel.
struct InfoPanel: View {
    let summary: InfoSummary
    let fileName: String?
    /// Opens the date correction when the place showing the panel offers it; nil leaves the date as text.
    var onAdjustDate: (() -> Void)?
    /// Shows the file in the Finder, for photos that are files of a folder; nil leaves the name alone.
    var onShowInFinder: (() -> Void)?

    var body: some View {
        if summary.isEmpty, onAdjustDate == nil {
            Text("No metadata").foregroundStyle(.secondary)
        }
        row("Camera", summary.camera)
        row("Lens", summary.lens)
        row("Exposure", summary.exposure)
        row("Size", summary.size)
        if summary.captured != .none || onAdjustDate != nil {
            if let onAdjustDate {
                // The date itself is the button: an icon next to it pushed the value onto a second line.
                LabeledContent("Captured") {
                    Button(capturedText, action: onAdjustDate)
                        .buttonStyle(.link)
                        .help("Adjust the date and time")
                }
            } else {
                LabeledContent("Captured", value: capturedText)
            }
        }
        if let fileName {
            if let onShowInFinder {
                LabeledContent("File") {
                    HStack(spacing: 6) {
                        Text(fileName)
                        FileActionsMenu(showInFinder: onShowInFinder)
                    }
                }
            } else {
                LabeledContent("File", value: fileName)
            }
        }
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ row: InfoSummary.Row) -> some View {
        switch row {
        case .none:
            EmptyView()
        case let .value(text):
            LabeledContent(title, value: text)
        case .mixed:
            LabeledContent(title) {
                Text("Mixed").foregroundStyle(.tertiary)
            }
        }
    }

    private var capturedText: String {
        switch summary.captured {
        case .none: "No date"
        case let .value(text): text
        case .mixed: "Mixed"
        }
    }
}

#Preview("One photo") {
    Form {
        Section("Info") {
            InfoPanel(summary: InfoSummary(metadata: ImageMetadata(pixelWidth: 6240, pixelHeight: 4160, captureDate: .now, cameraMake: "FUJIFILM",
                                                                   cameraModel: "X-T5", lens: "XF35mmF2 R WR", iso: 400, exposureTime: 0.004,
                                                                   aperture: 2.8, focalLength: 35)),
                      fileName: "DSCF1234.RAF", onShowInFinder: {})
        }
    }
    .formStyle(.grouped)
    .frame(width: 280, height: 320)
}
