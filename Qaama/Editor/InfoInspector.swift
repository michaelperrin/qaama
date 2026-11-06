import EditorKit
import ImageIOKit
import SwiftUI

/// The Info tab: the histogram of the current edit, what the file says about itself, and a map of
/// where it was taken when it says so.
struct InfoInspector: View {
    let model: EditorModel

    var body: some View {
        Form {
            Section {
                HistogramView(histogram: model.histogram)
                    .listRowInsets(EdgeInsets())
            }
            Section("Info") {
                InfoPanel(summary: InfoSummary(metadata: model.metadata), fileName: model.baseName)
            }
            if let location = model.metadata?.location {
                Section("Location") {
                    LocationMap(location: location)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .formStyle(.grouped)
    }
}
