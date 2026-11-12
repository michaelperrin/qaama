import EditorKit
import ImageIOKit
import LibraryKit
import SwiftUI

/// Right column of the grid, for the photos selected there, without opening them: their rating,
/// flag and keywords, to read and to change, and the same histogram, file details and map as the
/// editor's Info tab. With several photos, each line shows what they share.
struct LibraryInspector: View {
    let source: any LibrarySource
    let selection: Set<LibraryAsset.ID>
    /// Opens the Adjust Date & Time dialog for these photos; nil when the place showing the panel has none.
    var onAdjustDate: (([LibraryAsset]) -> Void)?

    @State private var model = AssetInfoModel()
    @Environment(\.undoManager) private var undoManager

    /// The selected photos, in a stable order, when there are few enough to compare; nil beyond
    /// that: resolving thousands of photos on every update would freeze the window.
    private var assets: [LibraryAsset]? {
        guard selection.count <= AssetInfoModel.selectionLimit else { return nil }
        return selection.sorted().compactMap { source.asset(id: $0) }
    }

    /// The dialog is offered where the source can store a corrected date.
    private var adjustDate: (([LibraryAsset]) -> Void)? {
        source.capabilities.contains(.captureDate) ? onAdjustDate : nil
    }

    var body: some View {
        let assets = assets
        Form {
            if let assets, !assets.isEmpty {
                if assets.count == 1 {
                    Section {
                        HistogramView(histogram: model.histogram)
                            .listRowInsets(EdgeInsets())
                    }
                }
                decisions(assets)
                if assets.count == 1 {
                    info(of: assets[0])
                } else {
                    info(shared: assets)
                }
            } else {
                Section("Info") {
                    Text(selection.isEmpty ? "No photo selected" : "\(selection.count) photos selected")
                        .foregroundStyle(.secondary)
                    if !selection.isEmpty {
                        Text("Details are shown for up to \(AssetInfoModel.selectionLimit) photos.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let adjustDate {
                            Button("Adjust Date & Time…") { adjustDate(selection.compactMap { source.asset(id: $0) }) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Any change to the photos (another selection, a rating, an edit, a corrected date) restarts
        // the task, which abandons the load in flight.
        .task(id: assets ?? []) {
            await model.show(assets ?? [], in: source)
        }
    }

    // MARK: - Decisions

    /// Rating, flag and keywords, for what the source can store. A change goes to every photo.
    @ViewBuilder
    private func decisions(_ assets: [LibraryAsset]) -> some View {
        let capabilities = source.capabilities
        if !capabilities.isDisjoint(with: [.rating, .flag, .keywords]) {
            Section {
                if capabilities.contains(.rating) {
                    let rating = model.rating(of: assets)
                    LabeledContent("Rating") {
                        HStack(spacing: 6) {
                            if rating == nil {
                                mixed
                            }
                            RatingView(rating: rating ?? 0) { value in
                                Task { await model.setRating(value, in: source, undoManager: undoManager) }
                            }
                        }
                    }
                }
                if capabilities.contains(.flag) {
                    let flag = model.flag(of: assets)
                    LabeledContent("Flag") {
                        HStack(spacing: 6) {
                            if flag == nil {
                                mixed
                            }
                            FlagView(flag: flag ?? .none) { value in
                                Task { await model.setFlag(value, in: source, undoManager: undoManager) }
                            }
                        }
                    }
                }
                if capabilities.contains(.keywords) {
                    // Nothing to edit until the model has read the keywords of these very photos.
                    let isReady = model.isShowing(assets) && model.hasLoadedKeywords
                    KeywordsField(keywords: isReady ? model.keywords : [], width: nil) { edited in
                        // A keyword half typed belongs to the photos it was typed for.
                        guard model.isShowing(assets) else { return }
                        Task { await model.setKeywords(edited, in: source, undoManager: undoManager) }
                    }
                    .disabled(!isReady)
                    .id(assets.map(\.id))
                    .help(assets.count == 1 ? "Keywords (comma separated). Return or a comma saves."
                        : "Keywords every selected photo has. One added here is added to all; one removed is removed from all.")
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                if assets.count > 1 {
                    Text("\(assets.count) Photos Selected")
                }
            }
        }
    }

    private var mixed: some View {
        Text("Mixed").font(.callout).foregroundStyle(.tertiary)
    }

    // MARK: - Info

    @ViewBuilder
    private func info(of asset: LibraryAsset) -> some View {
        let details = model.details(for: asset)
        Section {
            InfoPanel(summary: InfoSummary([details]), fileName: details.fileName,
                      onAdjustDate: adjustDate.map { open in { open([asset]) } },
                      onShowInFinder: source.fileURL(for: asset).map { url in { FinderReveal.show([url]) } })
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
    }

    /// What several photos share, once they have all been read.
    @ViewBuilder
    private func info(shared assets: [LibraryAsset]) -> some View {
        let summary = model.isShowing(assets) ? model.summary : nil
        Section {
            if let summary {
                InfoPanel(summary: summary, fileName: nil, onAdjustDate: adjustDate.map { open in { open(assets) } })
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(assets.count) photos…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Info")
        } footer: {
            if let summary, summary.unreadCount > 0 {
                Text(summary.unreadCount == 1 ? "Camera details are missing for 1 photo whose original is in iCloud."
                    : "Camera details are missing for \(summary.unreadCount) photos whose originals are in iCloud.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        .frame(width: EditorInspector.width, height: 600)
}

#Preview("Original in iCloud") {
    let source = SampleLibrarySource()
    source.cloudOnlyIDs = ["sample-1"]
    return LibraryInspector(source: source, selection: ["sample-1"])
        .frame(width: EditorInspector.width, height: 600)
}

#Preview("Several photos") {
    LibraryInspector(source: SampleLibrarySource(), selection: ["sample-0", "sample-2", "sample-4"])
        .frame(width: EditorInspector.width, height: 500)
}
