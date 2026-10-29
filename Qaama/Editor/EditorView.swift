import EditModel
import LibraryKit
import RenderEngine
import SwiftUI
import UniformTypeIdentifiers

/// Non-destructive editor: Metal canvas on the left, adjustments on the right. Shown in place of the
/// grid, not in a sheet: a Metal layer doesn't display inside macOS 27 sheets.
///
/// Opens the original through the library source, applies the recipe live, and stores the recipe
/// back (Photos adjustment data or sidecar) on Save.
struct EditorView: View {
    let assetID: LibraryAsset.ID
    let source: any LibrarySource
    let onClose: () -> Void

    @State private var renderer = CanvasRenderer()
    @State private var sourceImage: SourceImage?
    @State private var baseName = "Photo"
    @State private var recipe = EditRecipe.identity
    @State private var savedRecipe = EditRecipe.identity
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var exportDocument: JPEGDocument?
    @State private var isExporting = false
    @State private var keywords: [String] = []

    /// Live copy of the asset, so the rating reflects library changes.
    private var asset: LibraryAsset? {
        source.asset(id: assetID)
    }

    private var hasUnsavedChanges: Bool {
        recipe != savedRecipe
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                canvas
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                inspector
                    .frame(width: 260)
            }
            Divider()
            bottomBar
        }
        .task { await open() }
        .onChange(of: recipe) { _, newValue in
            if let sourceImage, let renderer {
                renderer.image = RenderPipeline.apply(newValue, to: sourceImage.image)
            }
        }
        .onDisappear {
            if let asset {
                source.endEditing(asset)
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .jpeg,
                      defaultFilename: "\(baseName) edited")
        { result in
            if case let .failure(error) = result {
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Subviews

    private var canvas: some View {
        ZStack {
            Color.black
            if let renderer {
                MetalCanvasView(renderer: renderer)
            } else {
                Text("Metal is not available on this Mac.").foregroundStyle(.white)
            }
            if sourceImage == nil, statusMessage == nil {
                ProgressView("Opening original…").tint(.white).foregroundStyle(.white)
            }
        }
    }

    private var inspector: some View {
        Form {
            Section("Light") {
                AdjustmentSlider(title: "Exposure", value: $recipe.exposure, range: EditRecipe.exposureRange, unit: "EV")
                AdjustmentSlider(title: "Contrast", value: $recipe.contrast, range: EditRecipe.contrastRange)
            }
            Section("Color") {
                AdjustmentSlider(title: "Saturation", value: $recipe.saturation, range: EditRecipe.saturationRange)
            }
            Section {
                Button("Reset Adjustments") { recipe = .identity }
                    .disabled(recipe.isIdentity)
            }
        }
        .formStyle(.grouped)
        .disabled(sourceImage == nil)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if let asset {
                Text(asset.creationDate?.formatted(date: .long, time: .shortened) ?? "Unknown date")
                if let sourceImage {
                    Text("\(Int(sourceImage.pixelSize.width)) × \(Int(sourceImage.pixelSize.height)) px")
                        .monospacedDigit()
                    if sourceImage.isRAW {
                        Text("RAW")
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.2), in: .capsule)
                    }
                }
                if let duration = renderer?.lastRenderDuration {
                    Text("render \(duration.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if source.capabilities.contains(.keywords) {
                    KeywordsField(keywords: keywords) { new in
                        keywords = new
                        update { try await source.setKeywords(new, for: asset) }
                    }
                }
                if source.capabilities.contains(.flag) {
                    FlagView(flag: asset.flag) { flag in update { try await source.setFlag(flag, for: asset) } }
                }
                if source.capabilities.contains(.rating) {
                    RatingView(rating: asset.rating) { rate($0) }
                    ratingShortcuts
                }
            }
            if let statusMessage {
                Text(statusMessage).foregroundStyle(.red).lineLimit(1)
            }
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Export JPEG…") { Task { await exportJPEG() } }
                .disabled(sourceImage == nil || isBusy)
            Button("Save") { Task { await save() } }
                .keyboardShortcut("s")
                .disabled(sourceImage == nil || isBusy || !hasUnsavedChanges)
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .font(.callout)
        .padding(12)
    }

    /// Hidden buttons so the 0–5 keys set the rating, as in most photo browsers.
    private var ratingShortcuts: some View {
        ForEach(0 ... 5, id: \.self) { value in
            Button("") { rate(value) }
                .keyboardShortcut(KeyEquivalent(Character("\(value)")), modifiers: [])
                .hidden()
                .frame(width: 0, height: 0)
        }
    }

    // MARK: - Actions

    private func open() async {
        guard let asset else { return }
        do {
            keywords = await source.keywords(for: asset)
            let input = try await source.editingInput(for: asset)
            if let url = input.imageURL {
                baseName = url.deletingPathExtension().lastPathComponent
            }
            if let data = input.recipeData {
                recipe = try EditRecipe(jsonData: data)
                savedRecipe = recipe
            }
            let renderSource: RenderSource
            if let url = input.imageURL {
                renderSource = .file(url)
            } else if let image = input.image {
                renderSource = .image(image)
            } else {
                throw LibrarySourceError.editingFailed("no image data")
            }
            let loaded = try await Task.detached(priority: .userInitiated) { try SourceImageLoader.load(renderSource) }.value
            sourceImage = loaded
            renderer?.image = RenderPipeline.apply(recipe, to: loaded.image)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Renders the full-size result off the main actor.
    private func renderJPEG() async throws -> Data {
        guard let sourceImage else { throw LibrarySourceError.assetUnavailable }
        let recipe = recipe
        return try await Task.detached(priority: .userInitiated) {
            try ImageExporter.jpegData(for: RenderPipeline.apply(recipe, to: sourceImage.image))
        }.value
    }

    private func save() async {
        guard let asset else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let output = try await EditingOutput(recipeData: recipe.jsonData(), renderedJPEG: renderJPEG(), isReset: recipe.isIdentity)
            try await source.saveEdit(output, for: asset)
            savedRecipe = recipe
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func exportJPEG() async {
        isBusy = true
        defer { isBusy = false }
        do {
            exportDocument = try await JPEGDocument(data: renderJPEG())
            isExporting = true
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func rate(_ value: Int) {
        guard let asset else { return }
        update { try await source.setRating(value, for: asset) }
    }

    /// Runs a decision (rating, flag, keywords) and shows its error, if any.
    private func update(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
