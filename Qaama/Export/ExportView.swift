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

    /// Settings pages.
    private enum Tab: String, CaseIterable, Identifiable {
        case format, frame, watermark, files
        var id: Self {
            self
        }

        var title: LocalizedStringKey {
            switch self {
            case .format: "Format"
            case .frame: "Frame"
            case .watermark: "Watermark"
            case .files: "Files"
            }
        }
    }

    private enum NamingMode: String, CaseIterable, Identifiable {
        case original, sequence
        var id: Self {
            self
        }
    }

    private enum WatermarkKind: String, CaseIterable, Identifiable {
        case text, image
        var id: Self {
            self
        }
    }

    @State private var isChoosingWatermarkPicture = false

    /// Frame aspect ratios offered, width / height; nil is an even border.
    private static let frameAspects: [(title: String, ratio: Double?)] = [
        ("Even", nil), ("1:1", 1), ("4:5", 0.8), ("5:4", 1.25), ("3:2", 1.5), ("2:3", 2 / 3.0),
        ("4:3", 4 / 3.0), ("3:4", 0.75), ("16:9", 16 / 9.0), ("9:16", 9 / 16.0),
    ]

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
        .task(id: model.previewKey) { await model.loadPreview() }
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

    @State private var isNamingPreset = false
    @State private var presetName = ""

    private var header: some View {
        ZStack {
            Picker("Settings", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack {
                Text(model.isBatch ? "Export \(model.items.count) Photos" : "Export Photo")
                    .font(.title3.bold())
                Spacer()
                presetMenu
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .alert("Save Export Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { model.savePreset(named: presetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Format, size, frame, watermark and file options are saved together.")
        }
    }

    /// Saved export presets; the label shows the one the current settings match, or Custom.
    private var presetMenu: some View {
        Menu {
            ForEach(model.presets.presets) { preset in
                Button {
                    model.apply(preset)
                } label: {
                    if preset == model.currentPreset {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
            if !model.presets.presets.isEmpty {
                Divider()
            }
            Button("Save Preset…") {
                presetName = model.currentPreset?.name ?? ""
                isNamingPreset = true
            }
            Button("Delete Preset") { model.deleteCurrentPreset() }
                .disabled(model.currentPreset == nil)
        } label: {
            Label(model.currentPreset?.name ?? "Custom", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Export presets")
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
            case .frame:
                Section {
                    Toggle("Frame", isOn: $model.settings.frame.isEnabled)
                }
                Section {
                    Picker("Aspect Ratio", selection: $model.settings.frame.aspectRatio) {
                        ForEach(Self.frameAspects, id: \.title) { aspect in
                            Text(aspect.title).tag(aspect.ratio)
                        }
                    }
                    percentSlider("Thickness", value: $model.settings.frame.thickness, in: ExportFrame.thicknessRange)
                    percentSlider("Corner Radius", value: $model.settings.frame.cornerRadius, in: ExportFrame.cornerRadiusRange)
                    ColorPicker("Color", selection: frameColor, supportsOpacity: false)
                }
                .disabled(!model.settings.frame.isEnabled)
            case .watermark:
                Section {
                    Toggle("Watermark", isOn: $model.settings.watermark.isEnabled)
                }
                Section {
                    Picker("Type", selection: watermarkKind) {
                        Text("Text").tag(WatermarkKind.text)
                        Text("Image").tag(WatermarkKind.image)
                    }
                    .pickerStyle(.segmented)
                    switch model.settings.watermark.kind {
                    case .text:
                        TextField("Text", text: watermarkText, prompt: Text("© Your name"))
                        Picker("Font", selection: $model.settings.watermark.fontName) {
                            ForEach(ExportWatermark.fonts, id: \.name) { font in
                                Text(font.title).tag(font.name)
                            }
                        }
                        ColorPicker("Color", selection: color($model.settings.watermark.color), supportsOpacity: false)
                    case let .image(name):
                        LabeledContent("Picture") {
                            HStack {
                                if let picture = model.watermarks.image(named: name) {
                                    Image(decorative: picture, scale: 1)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 28)
                                        .background(.quaternary, in: .rect(cornerRadius: 3))
                                }
                                Text(name.isEmpty ? "None" : name).lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { isChoosingWatermarkPicture = true }
                            }
                        }
                    }
                    Toggle("Add Shadow", isOn: $model.settings.watermark.hasShadow)
                }
                Section {
                    Picker("Position", selection: $model.settings.watermark.position) {
                        ForEach(ExportWatermark.Position.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .disabled(model.settings.watermark.isTiled)
                    percentSlider("Size", value: $model.settings.watermark.size, in: ExportWatermark.sizeRange)
                    percentSlider("Opacity", value: $model.settings.watermark.opacity, in: ExportWatermark.opacityRange)
                    Toggle("Tile", isOn: $model.settings.watermark.isTiled)
                }
                .disabled(!model.settings.watermark.isEnabled)
            case .files:
                Section("Naming") {
                    Picker("Names", selection: namingMode) {
                        Text("Original Names").tag(NamingMode.original)
                        Text("Sequence").tag(NamingMode.sequence)
                    }
                    if case let .sequence(prefix, start, digits) = model.settings.naming {
                        TextField("Prefix", text: Binding(get: { prefix }, set: { model.settings.naming = .sequence(prefix: $0, start: start, digits: digits) }))
                        LabeledContent("Start at") {
                            TextField("Start", value: Binding(get: { start }, set: { model.settings.naming = .sequence(prefix: prefix, start: max(0, $0), digits: digits) }),
                                      format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                        }
                        Stepper("Digits: \(digits)", value: Binding(get: { digits }, set: { model.settings.naming = .sequence(prefix: prefix, start: start, digits: $0) }),
                                in: ExportNaming.digitsRange)
                        LabeledContent("Example") {
                            Text("\(model.settings.naming.fileName(original: "", index: 0)).\(model.settings.format.fileExtension)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Existing Files") {
                    Picker("If a file exists", selection: $model.settings.existingFiles) {
                        Text("Keep both, number the new one").tag(ExportCollisionPolicy.rename)
                        Text("Overwrite").tag(ExportCollisionPolicy.overwrite)
                    }
                }
                Section("Metadata") {
                    Picker("Metadata", selection: $model.settings.metadata) {
                        Text("Keep all").tag(ExportMetadataPolicy.keep)
                        Text("Remove location").tag(ExportMetadataPolicy.stripLocation)
                        Text("Remove all").tag(ExportMetadataPolicy.strip)
                    }
                    Text("Camera, exposure and keyword metadata of the original file are copied into the export. Photos from the Photos library carry none for now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingWatermarkPicture, allowedContentTypes: [.png, .jpeg, .heic, .tiff]) { result in
            if case let .success(url) = result {
                model.useWatermarkPicture(at: url)
            }
        }
    }

    private var namingMode: Binding<NamingMode> {
        Binding(
            get: { model.settings.naming == .original ? .original : .sequence },
            set: { mode in
                switch mode {
                case .original: model.settings.naming = .original
                case .sequence: model.settings.naming = .sequence(prefix: "Photo-", start: 1, digits: 3)
                }
            }
        )
    }

    private var watermarkKind: Binding<WatermarkKind> {
        Binding(
            get: { model.settings.watermark.imageName == nil ? .text : .image },
            set: { kind in
                switch kind {
                case .text: model.settings.watermark.kind = .text(lastWatermarkText)
                case .image: model.settings.watermark.kind = .image(model.watermarks.names.first ?? "")
                }
            }
        )
    }

    /// Text kept while the picture type is selected, so switching back doesn't lose it.
    @State private var lastWatermarkText = "© "

    private var watermarkText: Binding<String> {
        Binding(
            get: {
                if case let .text(text) = model.settings.watermark.kind {
                    return text
                }
                return lastWatermarkText
            },
            set: {
                lastWatermarkText = $0
                model.settings.watermark.kind = .text($0)
            }
        )
    }

    private func percentSlider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    @Environment(\.self) private var environment

    private var frameColor: Binding<Color> {
        color($model.settings.frame.color)
    }

    /// SwiftUI color over an export color, resolved to sRGB components when set.
    private func color(_ binding: Binding<ExportColor>) -> Binding<Color> {
        Binding(
            get: {
                let color = binding.wrappedValue
                return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
            },
            set: { color in
                let resolved = color.resolve(in: environment)
                binding.wrappedValue = ExportColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue), alpha: 1)
            }
        )
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
