import EditorKit
import SwiftUI

/// The Info tab: the histogram of the current edit and what the file says about itself.
struct InfoInspector: View {
    let model: EditorModel

    var body: some View {
        Form {
            Section {
                HistogramView(histogram: model.histogram)
                    .listRowInsets(EdgeInsets())
            }
            Section("Info") {
                InfoPanel(model: model)
            }
        }
        .formStyle(.grouped)
    }
}
