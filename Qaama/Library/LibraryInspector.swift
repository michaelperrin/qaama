import EditorKit
import ImageIOKit
import LibraryKit
import SwiftUI

/// Right column of the grid: the Info panel of the photo selected there, the same histogram, file
/// details and map as the editor's Info tab, without opening the photo.
struct LibraryInspector: View {
    let source: any LibrarySource
    let selection: Set<LibraryAsset.ID>

    @State private var model = AssetInfoModel()

    /// What the panel depends on: another photo, or the same one edited since (its histogram changed).
    private struct ShownKey: Hashable {
        let id: LibraryAsset.ID?
        let modificationDate: Date?
    }

    /// The panel describes one photo: the only one selected.
    private var asset: LibraryAsset? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return source.asset(id: id)
    }

    var body: some View {
        let asset = asset
        Form {
            if let asset {
                let details = model.details(for: asset)
                Section {
                    HistogramView(histogram: model.histogram)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    InfoPanel(metadata: details.metadata, fileName: details.fileName)
                } header: {
                    Text("Info")
                } footer: {
                    if details.isOriginalInCloud {
                        originalInCloudNote
                    }
                }
                if let location = details.metadata?.location {
                    Section("Location") {
                        LocationMap(location: location)
                            .listRowInsets(EdgeInsets())
                    }
                }
            } else {
                Section("Info") {
                    Text(selection.isEmpty ? "No photo selected" : "\(selection.count) photos selected")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Another selection restarts the task, which abandons the load in flight.
        .task(id: ShownKey(id: asset?.id, modificationDate: asset?.modificationDate)) {
            await model.show(asset, in: source)
        }
    }

    /// Selecting a photo never downloads anything; the camera details of an original kept in iCloud
    /// come when the user asks for them here.
    private var originalInCloudNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.originalDownloadFailed
                ? "The original couldn't be downloaded. Check the connection and try again."
                : "The original is in iCloud. Download it to see the camera and exposure details.")
            if model.isDownloadingOriginal {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…")
                }
            } else {
                Button("Download Original") { model.downloadOriginal(in: source) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("One photo") {
    LibraryInspector(source: SampleLibrarySource(), selection: ["sample-1"])
        .frame(width: EditorInspector.width, height: 500)
}

#Preview("Original in iCloud") {
    let source = SampleLibrarySource()
    source.cloudOnlyIDs = ["sample-1"]
    return LibraryInspector(source: source, selection: ["sample-1"])
        .frame(width: EditorInspector.width, height: 500)
}

#Preview("Several photos") {
    LibraryInspector(source: SampleLibrarySource(), selection: ["sample-1", "sample-2"])
        .frame(width: EditorInspector.width, height: 500)
}
