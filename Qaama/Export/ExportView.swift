import EditorKit
import LibraryKit
import RenderEngine
import SwiftUI
import UniformTypeIdentifiers

/// Export sheet: tabs of settings on top, the selected photo large on the left with the active tab's
/// form on the right, and a filmstrip of every photo to export at the bottom. Plain SwiftUI images
/// for the pictures, since a Metal layer shows nothing inside a sheet.
struct ExportView: View {
    @Bindable var model: ExportModel
    /// Called when the sheet should close, after a successful export or a cancel.
    let onDone: () -> Void

    @State private var tab: Tab = .format
    @State private var document: ExportDocument?
    @State private var isSaving = false
    @State private var isChoosingFolder = false
    /// Set once a batch has run, to show its outcome in place of the settings.
    @State private var batchWritten: Int?

    /// Settings pages; more come with frames, watermarks and naming.
    private enum Tab: String, CaseIterable, Identifiable {
        case format
        var id: Self {
            self
        }

        var title: LocalizedStringKey {
            switch self {
            case .format: "Format"
            }
        }
    }

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
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                Group {
                    if let batchWritten {
                        outcome(written: batchWritten)
                    } else {
                        settingsForm
                    }
                }
                .frame(width: 400)
            }
            Divider()
            filmstrip
            Divider()
            footer
        }
        .frame(width: 1080, height: 720)
        .task(id: model.selectedItemID) { await model.loadPreview() }
        .fileExporter(isPresented: $isSaving, document: document, contentType: model.settings.format.type,
                      defaultFilename: model.defaultFileName)
        { result in
            if case .success = result {
                onDone()
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(folder) = result {
                Task {
                    let written = await model.exportAll(to: folder)
                    if model.failures.isEmpty, written == model.items.count {
                        onDone()
                    } else {
                        batchWritten = written
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(model.isBatch ? "Export \(model.items.count) Photos" : "Export Photo")
                .font(.title3.bold())
            Spacer()
            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            // Balances the title so the tabs stay centered.
            Text(model.isBatch ? "Export \(model.items.count) Photos" : "Export Photo")
                .font(.title3.bold())
                .hidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsForm: some View {
        Form {
            switch tab {
            case .format:
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
        }
        .formStyle(.grouped)
    }

    /// What a batch left behind: how many files, and which photos failed.
    private func outcome(written: Int) -> some View {
        List {
            Text("\(written) of \(model.items.count) photos exported.")
            ForEach(model.failures) { failure in
                Label {
                    Text(failure.name).bold() + Text(": \(failure.message)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(model.items) { item in
                    ExportStripTile(model: model, item: item, isSelected: item.id == model.selectedItemID)
                        .onTapGesture { model.selectedItemID = item.id }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(height: 132)
    }

    private var footer: some View {
        HStack {
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            if model.isBusy, model.isBatch {
                ProgressView(value: Double(model.completedCount), total: Double(model.items.count))
                    .frame(width: 160)
                Button("Stop") { model.cancel() }
            } else if model.isBusy {
                ProgressView().controlSize(.small)
            }
            if batchWritten == nil {
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.preview == nil)
            } else {
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
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
        if model.isBatch {
            isChoosingFolder = true
            return
        }
        guard let data = await model.encodeSelected() else { return }
        document = ExportDocument(data: data)
        isSaving = true
    }
}

/// One photo of the filmstrip: its thumbnail and the file name it will be written under.
private struct ExportStripTile: View {
    let model: ExportModel
    let item: ExportItem
    let isSelected: Bool

    @State private var image: CGImage?
    @State private var name: String?
    @Environment(\.displayScale) private var displayScale

    private let side: CGFloat = 80

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: side, height: side)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            }
            Text(model.outputFileName(for: item) ?? name ?? " ")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: side + 16)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .task {
            name = await model.name(for: item)
            image = await model.thumbnail(for: item, pixelSize: CGSize(width: side * displayScale, height: side * displayScale))
        }
        .onChange(of: model.preview) {
            // A photo without a library thumbnail (the editor's) shows its preview once rendered.
            if image == nil {
                Task { image = await model.thumbnail(for: item, pixelSize: CGSize(width: side * displayScale, height: side * displayScale)) }
            }
        }
    }
}
