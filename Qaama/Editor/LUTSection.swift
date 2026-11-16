import EditModel
import EditorKit
import SwiftUI
import UniformTypeIdentifiers

/// The LUT card of the Adjustments tab: its switch, the menu of the library's tables, which shows
/// each on the canvas as the pointer passes over it, the library's commands, and the intensity.
struct LUTSection: View {
    let model: EditorModel
    let luts: LUTStore

    @State private var isImporting = false
    /// What went wrong with the library, for the alert.
    @State private var failure: Failure?
    /// The table the user asked to delete, until they confirm.
    @State private var pendingDeletion: String?

    private var lut: LUT? {
        model.adjustments.lut
    }

    var body: some View {
        Section {
            SectionSwitch("LUT", isOn: isEnabled)
            Group {
                // An empty library has nothing to choose from: lead to the one thing to do.
                if luts.names.isEmpty, lut?.name == nil {
                    Button("Import LUTs…") { isImporting = true }
                        .controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        LUTPopUpButton(names: luts.names, selection: lut?.name, onHighlight: model.previewLUT, onChoose: model.chooseLUT)
                        libraryMenu
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [Self.cubeFile], allowsMultipleSelection: true) { result in
                if case let .success(urls) = result {
                    Task { await importFiles(at: urls) }
                }
            }
            .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: {
                if !$0 {
                    failure = nil
                }
            })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure?.message ?? "")
            }
            .confirmationDialog("Delete the LUT “\(pendingDeletion ?? "")”?", isPresented: Binding(get: { pendingDeletion != nil }, set: {
                if !$0 {
                    pendingDeletion = nil
                }
            }), presenting: pendingDeletion) { name in
                Button("Delete", role: .destructive) { delete(name) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Photos that use this LUT will be shown without it. This can't be undone.")
            }
            AdjustmentSlider(title: "Intensity", value: intensity, range: LUT.intensityRange, resetValue: 1,
                             onEditingEnded: model.commitChange)
                // Nothing to mix while the LUT is off or has no table.
                .disabled(lut?.isEnabled != true || lut?.name == nil)
        }
        // Tables added to the folder by hand, or from another window.
        .onAppear { luts.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in luts.reload() }
    }

    private struct Failure {
        let title: LocalizedStringKey
        let message: String
    }

    /// `.cube` belongs to no app in particular: the system knows it by its extension only.
    private static let cubeFile = UTType(filenameExtension: "cube", conformingTo: .data) ?? .data

    /// The ellipsis button next to the menu, with what can be done with the library.
    private var libraryMenu: some View {
        Menu {
            Button("Import LUTs…") { isImporting = true }
            Button("Show LUTs in Finder") { FinderReveal.show([luts.directory]) }
                .disabled(luts.names.isEmpty)
            if !luts.names.isEmpty {
                Divider()
                Menu("Delete LUT") {
                    ForEach(luts.names, id: \.self) { name in
                        Button(name, role: .destructive) { pendingDeletion = name }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Import and manage LUTs")
        .accessibilityLabel("LUT library")
    }

    /// Off until a table is chosen or the switch is first turned on; switching it off afterwards
    /// keeps the table and its intensity.
    private var isEnabled: Binding<Bool> {
        Binding(
            get: { lut?.isEnabled ?? false },
            set: { enabled in
                var lut = lut ?? LUT()
                lut.isEnabled = enabled
                model.adjustments.lut = lut
                model.commitChange()
            }
        )
    }

    private var intensity: Binding<Double> {
        Binding(
            get: { lut?.intensity ?? 1 },
            set: { model.adjustments.lut?.intensity = $0 }
        )
    }

    /// Copies the files into the library. One file is a look to try: it goes on the photo, which
    /// Undo takes back; several are a pack, left in the menu.
    private func importFiles(at urls: [URL]) async {
        let report = await luts.importFiles(at: urls)
        // The photo may have been left while the files were read.
        if urls.count == 1, let name = report.imported.first, !model.isClosed {
            model.chooseLUT(.table(name))
        }
        if !report.failures.isEmpty {
            failure = Failure(title: "Couldn't Import LUT", message: report.failures.joined(separator: "\n"))
        }
    }

    private func delete(_ name: String) {
        do {
            try luts.delete(name)
        } catch {
            failure = Failure(title: "Couldn't Delete LUT", message: error.localizedDescription)
        }
    }
}
