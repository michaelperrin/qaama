import Foundation
import LibraryKit
import OSLog

/// What the user decides about a photo: its rating, its pick / reject flag, its keywords.
public nonisolated enum LibraryDecision: Hashable, Sendable {
    case rating(Int)
    case flag(ItemFlag)
    case keywords([String])

    /// The name the Edit menu gives to undoing it.
    public var actionName: String {
        switch self {
        case .rating: "Rating"
        case .flag: "Flag"
        case .keywords: "Keywords"
        }
    }
}

public extension LibrarySource {
    /// Writes a decision about a photo.
    func apply(_ decision: LibraryDecision, to asset: LibraryAsset) async throws {
        switch decision {
        case let .rating(rating): try await setRating(rating, for: asset)
        case let .flag(flag): try await setFlag(flag, for: asset)
        case let .keywords(keywords): try await setKeywords(keywords, for: asset)
        }
    }

    /// The decision of the same kind in place for a photo, read from the source's current state:
    /// what to write back to undo `decision`.
    func current(_ decision: LibraryDecision, of asset: LibraryAsset) async -> LibraryDecision {
        let now = self.asset(id: asset.id) ?? asset
        switch decision {
        case .rating: return .rating(now.rating)
        case .flag: return .flag(now.flag)
        case .keywords: return await .keywords(keywords(for: now))
        }
    }
}

/// Decisions about photos (rating, flag, keywords) and corrections to what they say about
/// themselves (their capture date for now), written through the library source for one photo or
/// many, as one undoable step.
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

    /// Writes a decision per photo, after recording the ones in place so the whole step can be undone;
    /// the undo registers the redo the same way. Returns the number of photos updated. Photos that
    /// fail are logged and skipped; when none could be written, the first error is thrown.
    @MainActor
    @discardableResult
    public static func apply(_ decisions: [(LibraryAsset, LibraryDecision)], in source: any LibrarySource, undoManager: UndoManager?) async throws -> Int {
        var previous: [(LibraryAsset, LibraryDecision)] = []
        var written: [(LibraryAsset, LibraryDecision)] = []
        var firstError: (any Error)?
        for (asset, decision) in decisions {
            let before = await source.current(decision, of: asset)
            // Already so: nothing to write, and nothing to undo.
            if before == decision {
                continue
            }
            do {
                try await source.apply(decision, to: asset)
                previous.append((asset, before))
                written.append((asset, decision))
            } catch {
                firstError = firstError ?? error
                logger.error("\(decision.actionName, privacy: .public) of \(asset.id, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let undoManager, let actionName = written.first?.1.actionName {
            register(with: undoManager, restore: previous, redo: written, in: source, actionName: actionName)
        }
        if written.isEmpty, let firstError {
            throw firstError
        }
        return written.count
    }

    /// Same pattern as for the dates below: the undo registers its own inverse synchronously, then writes.
    @MainActor
    private static func register(with undoManager: UndoManager, restore: [(LibraryAsset, LibraryDecision)],
                                 redo: [(LibraryAsset, LibraryDecision)], in source: any LibrarySource, actionName: String)
    {
        undoManager.registerUndo(withTarget: source as AnyObject) { _ in
            MainActor.assumeIsolated {
                register(with: undoManager, restore: redo, redo: restore, in: source, actionName: actionName)
            }
            Task { @MainActor in
                _ = try? await apply(restore, in: source, undoManager: nil)
            }
        }
        undoManager.setActionName(actionName)
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
