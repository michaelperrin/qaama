import EditorKit
import LibraryKit
import RenderEngine
import SwiftUI

/// Photo facts, decisions (keywords, flag, rating), status, and the export / save / close buttons.
struct EditorBottomBar: View {
    let model: EditorModel
    let onExport: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if let asset = model.asset {
                Text(asset.creationDate?.formatted(date: .long, time: .shortened) ?? "Unknown date")
                    .lineLimit(1)
                if let sourceImage = model.sourceImage {
                    Text("\(Int(sourceImage.pixelSize.width)) × \(Int(sourceImage.pixelSize.height)) px")
                        .monospacedDigit()
                    if sourceImage.isRAW {
                        Text("RAW")
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.2), in: .capsule)
                    }
                }
                if let duration = model.renderer?.lastRenderDuration {
                    // Fixed width: this text changes on every frame, and a changing width would make the
                    // window columns shift while a slider is dragged.
                    Text("render \(duration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                }
                Spacer()
                if model.source.capabilities.contains(.keywords) {
                    KeywordsField(keywords: model.keywords) { new in Task { await model.setKeywords(new) } }
                }
                if model.source.capabilities.contains(.flag) {
                    FlagView(flag: asset.flag) { flag in Task { await model.setFlag(flag) } }
                }
                if model.source.capabilities.contains(.rating) {
                    RatingView(rating: asset.rating) { value in Task { await model.setRating(value) } }
                    ratingShortcuts
                }
            }
            if let statusMessage = model.statusMessage {
                Text(statusMessage).foregroundStyle(.red).lineLimit(1).layoutPriority(-1)
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Button {} label: {
                Label("Compare", systemImage: model.isShowingOriginal ? "square.filled.on.square" : "square.on.square")
            }
            .buttonStyle(.bordered)
            .disabled(!model.isOpen)
            .help("Hold to see the original")
            .onLongPressGesture(minimumDuration: 0, pressing: { pressing in model.isShowingOriginal = pressing }, perform: {})
            Button("Export…", action: onExport)
                .disabled(!model.canExport)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
        .padding(12)
    }

    /// Hidden buttons so the 0–5 keys set the rating, as in most photo browsers.
    private var ratingShortcuts: some View {
        ForEach(0 ... 5, id: \.self) { value in
            Button("") { Task { await model.setRating(value) } }
                .keyboardShortcut(KeyEquivalent(Character("\(value)")), modifiers: [])
                .hidden()
                .frame(width: 0, height: 0)
        }
    }
}

#Preview {
    EditorBottomBar(model: EditorModel(assetID: "sample-1", source: SampleLibrarySource(), renderer: nil), onExport: {}, onClose: {})
        .frame(width: 1000)
}
