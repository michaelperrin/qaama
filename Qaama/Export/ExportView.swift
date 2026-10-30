import EditorKit
import RenderEngine
import SwiftUI

/// Export sheet: the preview of the first photo on the left, the file settings on the right. A plain
/// SwiftUI image for the preview, since a Metal layer shows nothing inside a sheet.
struct ExportView: View {
    @Bindable var model: ExportModel
    /// Called when the sheet should close, after a successful export or a cancel.
    let onDone: () -> Void

    @State private var document: ExportDocument?
    @State private var isSaving = false

    private enum SizeMode: String, CaseIterable, Identifiable {
        case original, width, height, longEdge
        var id: Self {
            self
        }

        var title: LocalizedStringKey {
            switch self {
            case .original: "Original"
            case .width: "Width"
            case .height: "Height"
            case .longEdge: "Long Edge"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(width: 440)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Export Photo")
                    .font(.title2.bold())
                    .padding()
                Form {
                    Section("File") {
                        Picker("Format", selection: $model.settings.format) {
                            ForEach(ExportFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        if model.settings.format.isLossy {
                            LabeledContent("Quality") {
                                HStack {
                                    Slider(value: $model.settings.quality, in: ExportSettings.qualityRange)
                                    Text(model.settings.quality, format: .percent.precision(.fractionLength(0)))
                                        .monospacedDigit()
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    }
                    Section("Size") {
                        Picker("Size", selection: sizeMode) {
                            ForEach(SizeMode.allCases) { Text($0.title).tag($0) }
                        }
                        if model.settings.size != .original {
                            LabeledContent("Pixels") {
                                TextField("Pixels", value: pixels, format: .number.grouping(.never))
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 90)
                            }
                        }
                        LabeledContent("Output") {
                            Text(outputDescription)
                                .foregroundStyle(model.isUpscaling ? .orange : .secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .formStyle(.grouped)
                HStack {
                    if let message = model.errorMessage {
                        Text(message).foregroundStyle(.red).lineLimit(2)
                    }
                    Spacer()
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancel", action: onDone)
                        .keyboardShortcut(.cancelAction)
                    Button("Export…") { Task { await export() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isBusy || model.preview == nil)
                }
                .padding()
            }
            .frame(minWidth: 460)
        }
        .frame(width: 960, height: 560)
        .task { await model.loadPreview() }
        .fileExporter(isPresented: $isSaving, document: document, contentType: model.settings.format.type,
                      defaultFilename: model.defaultFileName)
        { result in
            if case .success = result {
                onDone()
            }
        }
    }

    private var preview: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(24)
            } else if model.errorMessage == nil {
                ProgressView("Rendering preview…")
                    .controlSize(.small)
            }
        }
    }

    private var outputDescription: String {
        guard let output = model.outputPixelSize else { return "…" }
        var text = "\(Int(output.width)) × \(Int(output.height)) px"
        if model.isUpscaling {
            text += " (enlarged)"
        }
        return text
    }

    /// The size mode as a picker value; switching modes keeps the pixel count typed so far.
    private var sizeMode: Binding<SizeMode> {
        Binding(
            get: {
                switch model.settings.size {
                case .original: .original
                case .width: .width
                case .height: .height
                case .longEdge: .longEdge
                }
            },
            set: { mode in
                let current = model.settings.size.pixels ?? Int(model.sourcePixelSize.map { max($0.width, $0.height) } ?? 2048)
                switch mode {
                case .original: model.settings.size = .original
                case .width: model.settings.size = .width(current)
                case .height: model.settings.size = .height(current)
                case .longEdge: model.settings.size = .longEdge(current)
                }
            }
        )
    }

    private var pixels: Binding<Int> {
        Binding(
            get: { model.settings.size.pixels ?? 0 },
            set: { value in
                let clamped = max(1, value)
                switch model.settings.size {
                case .original: break
                case .width: model.settings.size = .width(clamped)
                case .height: model.settings.size = .height(clamped)
                case .longEdge: model.settings.size = .longEdge(clamped)
                }
            }
        )
    }

    private func export() async {
        guard let data = await model.encodeFirst() else { return }
        document = ExportDocument(data: data)
        isSaving = true
    }
}
