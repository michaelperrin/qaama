import Foundation
import LibraryKit
import Observation

/// The Adjust Date & Time dialog, without its view: the photos to correct, the correction being
/// composed (a date for all, or a shift of each photo's own date), what it does to each photo, one
/// at a time, and its application as one undoable step.
///
/// The JPEG twin of a RAW + JPEG pair stored as two photos follows its RAW, shown or not: left
/// behind, the pair would come apart.
@Observable
public final class CaptureDateEditModel: Identifiable {
    public enum Mode: Hashable, Sendable, CaseIterable {
        /// Every photo gets the same date.
        case set
        /// Every photo moves by the same amount from its own date.
        case shift
    }

    public let source: any LibrarySource
    /// The photos the user selected, twins not included: what the dialog counts and shows. Earliest
    /// first, undated last, so the example shown is the same however the selection was made.
    public let assets: [LibraryAsset]
    public var mode = Mode.set
    /// The date given to every photo in `set` mode.
    public var date: Date
    /// Starts at nothing: the dialog suggests no correction of its own.
    public var shift = DateShift()
    public private(set) var isApplying = false
    /// What went wrong the last time the correction was applied, to show as is.
    public private(set) var errorMessage: String?

    /// The photos written, twins included, with the dates they had when the dialog opened.
    private let targets: [(asset: LibraryAsset, date: Date?)]

    public init(assets: [LibraryAsset], source: any LibrarySource) {
        self.source = source
        let assets = assets.sorted { (source.captureDate(for: $0) ?? .distantFuture) < (source.captureDate(for: $1) ?? .distantFuture) }
        self.assets = assets
        var seen = Set(assets.map(\.id))
        var all = assets
        for asset in assets {
            if let twinID = asset.pairedAssetID, seen.insert(twinID).inserted, let twin = source.asset(id: twinID) {
                all.append(twin)
            }
        }
        targets = all.map { ($0, source.captureDate(for: $0)) }
        date = DateAdjustment.wholeSeconds(targets.lazy.compactMap(\.date).first ?? .now)
    }

    public var adjustment: DateAdjustment {
        switch mode {
        case .set: .set(date)
        case .shift: .shift(shift)
        }
    }

    /// Position in `assets` of the photo the dialog shows the result for; it opens on the earliest.
    public private(set) var exampleIndex = 0

    /// The photo the dialog shows the result for.
    public var exampleAsset: LibraryAsset? {
        assets.indices.contains(exampleIndex) ? assets[exampleIndex] : nil
    }

    /// Its date when the dialog opened; nil when it has none.
    public var exampleDate: Date? {
        targets.indices.contains(exampleIndex) ? targets[exampleIndex].date : nil
    }

    /// What the correction makes of that date; nil when a shift has no date to move.
    public var adjustedExampleDate: Date? {
        adjustment.applied(to: exampleDate)
    }

    public var canShowPreviousExample: Bool {
        exampleIndex > 0
    }

    public var canShowNextExample: Bool {
        exampleIndex < assets.count - 1
    }

    /// Steps through the selected photos, earliest to latest, to check the result on any of them.
    public func showPreviousExample() {
        exampleIndex = max(exampleIndex - 1, 0)
    }

    public func showNextExample() {
        exampleIndex = min(exampleIndex + 1, max(assets.count - 1, 0))
    }

    /// Derives the shift from the real date of the photo shown: every photo then moves by the amount
    /// that takes this one there. Nothing happens when the photo shown has no date to start from.
    public func shiftSoExampleBecomes(_ target: Date, calendar: Calendar = .current) {
        guard let exampleDate else { return }
        mode = .shift
        shift = DateShift(from: exampleDate, to: target, calendar: calendar)
    }

    /// Selected photos a shift leaves alone: they have no date to move.
    public var undatedCount: Int {
        mode == .shift ? targets.prefix(assets.count).count(where: { $0.date == nil }) : 0
    }

    /// The dates to write: only the photos the correction actually changes.
    var changes: [(LibraryAsset, Date?)] {
        targets.compactMap { target in
            guard let new = adjustment.applied(to: target.date), new != target.date.map(DateAdjustment.wholeSeconds) else { return nil }
            return (target.asset, new)
        }
    }

    public var canApply: Bool {
        !isApplying && !changes.isEmpty
    }

    /// Writes the correction. Returns true when the dialog can close; otherwise `errorMessage` says why not.
    public func apply(undoManager: UndoManager?) async -> Bool {
        guard canApply else { return false }
        isApplying = true
        defer { isApplying = false }
        do {
            try await MetadataEditing.setCaptureDates(changes, in: source, undoManager: undoManager)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
