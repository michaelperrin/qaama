import EditorKit
import LibraryKit
import SwiftUI

/// The Adjust Date & Time dialog: gives every selected photo a date, or moves each one from its own
/// date by so many years, months, days, hours and minutes, and shows what that does to each photo,
/// one at a time.
///
/// Shown in a sheet, which has an undo manager of its own: the window's is handed in, so the
/// correction lands in the window's Edit menu.
struct CaptureDateEditView: View {
    @Bindable var model: CaptureDateEditModel
    let undoManager: UndoManager?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Adjust Date & Time").font(.headline)
                Text(model.assets.count == 1 ? "1 photo" : "\(model.assets.count) photos")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    Picker("Change", selection: $model.mode) {
                        Text("Set Date").tag(CaptureDateEditModel.Mode.set)
                        Text("Shift").tag(CaptureDateEditModel.Mode.shift)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch model.mode {
                    case .set: setControls
                    case .shift: shiftControls
                    }
                } footer: {
                    Text(explanation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    HStack(spacing: 12) {
                        if let asset = model.exampleAsset {
                            ExampleThumbnail(asset: asset, source: model.source)
                        }
                        VStack(spacing: 8) {
                            LabeledContent("Before", value: Self.text(model.exampleDate))
                            Divider()
                            if let realDate {
                                DatePicker("After", selection: realDate, displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.field)
                            } else {
                                LabeledContent("After", value: Self.text(model.adjustedExampleDate))
                            }
                        }
                    }
                    if model.assets.count > 1 {
                        exampleStepper
                    }
                } header: {
                    Text("Result")
                } footer: {
                    if realDate != nil {
                        Text(model.assets.count == 1 ? "Or enter the real date of the photo as After: the shift follows."
                            : "Or enter the real date of this photo as After: the shift follows, and every photo moves by the same amount.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout).lineLimit(2)
                }
                Spacer()
                if model.isApplying {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Task {
                        if await model.apply(undoManager: undoManager) {
                            onClose()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// In shift mode the result of the photo shown can be typed instead of the shift: the date it was
    /// really taken at, from which the shift is derived. Nil when there is nothing to derive it from.
    private var realDate: Binding<Date>? {
        guard model.mode == .shift, let shown = model.adjustedExampleDate else { return nil }
        return Binding(get: { shown }, set: { model.shiftSoExampleBecomes($0) })
    }

    /// Steps through the selected photos, earliest first, to check the result on any of them.
    private var exampleStepper: some View {
        HStack {
            Button("Previous Photo", systemImage: "chevron.left") { model.showPreviousExample() }
                .disabled(!model.canShowPreviousExample)
                .help("Previous photo")
            Spacer()
            Text("Photo \(model.exampleIndex + 1) of \(model.assets.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Next Photo", systemImage: "chevron.right") { model.showNextExample() }
                .disabled(!model.canShowNextExample)
                .help("Next photo")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    /// To the minute: SwiftUI's date picker has no seconds on macOS, so the date keeps the seconds it
    /// came with (those of the earliest photo). A shift is the way to move seconds along.
    private var setControls: some View {
        DatePicker("Date", selection: $model.date, displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.field)
    }

    /// Three rows rather than one per unit: which way, the calendar part, the clock part.
    @ViewBuilder
    private var shiftControls: some View {
        Picker("Direction", selection: $model.shift.direction) {
            Text("Later").tag(DateShift.Direction.later)
            Text("Earlier").tag(DateShift.Direction.earlier)
        }
        .pickerStyle(.segmented)
        LabeledContent("Date") {
            HStack(spacing: 10) {
                amountField("years", value: $model.shift.years)
                amountField("months", value: $model.shift.months)
                amountField("days", value: $model.shift.days)
            }
        }
        LabeledContent("Time") {
            HStack(spacing: 10) {
                amountField("hours", value: $model.shift.hours)
                amountField("minutes", value: $model.shift.minutes)
            }
        }
    }

    /// A number to type, followed by its unit; the up and down arrow keys step it, for the common
    /// "one more hour".
    private func amountField(_ unit: LocalizedStringKey, value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            TextField(unit, value: value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .onKeyPress(.upArrow) {
                    value.wrappedValue += 1
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    value.wrappedValue -= 1
                    return .handled
                }
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private var explanation: String {
        switch model.mode {
        case .set:
            return model.assets.count == 1 ? "The original file is not modified; exports carry the new date."
                : "Every selected photo gets this same date. The original files are not modified; exports carry the new date."
        case .shift:
            var text = "Each photo moves by this amount from its own date. The original files are not modified; exports carry the new dates."
            if model.undatedCount > 0 {
                text += model.undatedCount == 1 ? " 1 photo has no date and stays as it is." : " \(model.undatedCount) photos have no date and stay as they are."
            }
            return text
        }
    }

    private static func text(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "No date"
    }
}

/// The photo whose result the dialog shows, small and without the grid's badges.
private struct ExampleThumbnail: View {
    let asset: LibraryAsset
    let source: any LibrarySource

    private static let side: CGFloat = 56
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(.rect(cornerRadius: 5))
        .task(id: asset.id) {
            image = await source.thumbnail(for: asset, pixelSize: CGSize(width: Self.side * displayScale, height: Self.side * displayScale))
        }
    }
}

#Preview("One photo") {
    let source = SampleLibrarySource()
    CaptureDateEditView(model: CaptureDateEditModel(assets: [source.assets[0]], source: source), undoManager: nil) {}
}

#Preview("Several photos, shift") {
    let source = SampleLibrarySource()
    let model = CaptureDateEditModel(assets: Array(source.assets.prefix(5)), source: source)
    model.mode = .shift
    return CaptureDateEditView(model: model, undoManager: nil) {}
}
