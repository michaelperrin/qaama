import Foundation
import LibraryKit
import OSLog

/// Corrections to what photos say about themselves (their capture date for now), written through
/// the library source for one photo or many, as one undoable step.
public nonisolated enum MetadataEditing {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "MetadataEditing")
    static let captureDateActionName = "Adjust Date & Time"

    /// Writes a capture date per photo (nil removes a correction, see `LibrarySource.setCaptureDate`),
    /// after recording the dates in place so the whole step can be undone; the undo registers the redo
    /// the same way. Returns the number of photos updated. Photos that fail are logged and skipped;
    /// when none could be written, the first error is thrown.
    @MainActor
    @discardableResult
    public static func setCaptureDates(_ dates: [(LibraryAsset, Date?)], in source: any LibrarySource, undoManager: UndoManager?) async throws -> Int {
        var previous: [(LibraryAsset, Date?)] = []
        var written: [(LibraryAsset, Date?)] = []
        var firstError: (any Error)?
        for (asset, date) in dates {
            let before = source.captureDate(for: asset)
            do {
                try await source.setCaptureDate(date, for: asset)
                previous.append((asset, before))
                written.append((asset, date))
            } catch {
                firstError = firstError ?? error
                logger.error("Capture date of \(asset.id, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let undoManager, !written.isEmpty {
            register(with: undoManager, restore: previous, redo: written, in: source)
        }
        if written.isEmpty, let firstError {
            throw firstError
        }
        logger.notice("Corrected the capture date of \(written.count) photos")
        return written.count
    }

    /// Registers an undo that restores `restore`. Performed by the manager, it first registers its own
    /// inverse (the redo) synchronously, then writes; the source outlives the window's undo stack,
    /// which is what the target must do.
    @MainActor
    private static func register(with undoManager: UndoManager, restore: [(LibraryAsset, Date?)], redo: [(LibraryAsset, Date?)],
                                 in source: any LibrarySource)
    {
        undoManager.registerUndo(withTarget: source as AnyObject) { _ in
            MainActor.assumeIsolated {
                register(with: undoManager, restore: redo, redo: restore, in: source)
            }
            Task { @MainActor in
                _ = try? await setCaptureDates(restore, in: source, undoManager: nil)
            }
        }
        undoManager.setActionName(captureDateActionName)
    }
}
