import Foundation
import ImageIOKit
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
/// themselves (their capture date, where they were taken), written through the library source for
/// one photo or many, as one undoable step.
public nonisolated enum MetadataEditing {
    private static let logger = Logger(subsystem: "fr.michaelperrin.qaama", category: "MetadataEditing")
    static let captureDateActionName = "Adjust Date & Time"
    public static let locationActionName = "Assign Location"
    static let removeLocationActionName = "Remove Location"
    static let revertLocationActionName = "Revert to Original Location"

    /// Writes a capture date per photo (nil removes a correction, see `LibrarySource.setCaptureDate`),
    /// as one undoable step. Returns the number of photos updated. Photos that fail are logged and
    /// skipped; when none could be written, the first error is thrown.
    @MainActor
    @discardableResult
    public static func setCaptureDates(_ dates: [(LibraryAsset, Date?)], in source: any LibrarySource, undoManager: UndoManager?) async throws -> Int {
        let count = try await write(dates, field: "Capture date", actionName: captureDateActionName, in: source, undoManager: undoManager,
                                    current: { source.captureDate(for: $0) }, write: { try await source.setCaptureDate($0, for: $1) },
                                    again: { try await setCaptureDates($0, in: source, undoManager: nil) })
        logger.notice("Corrected the capture date of \(count) photos")
        return count
    }

    /// Writes a location per photo (nil removes a correction or the position, see
    /// `LibrarySource.setLocation`), as one undoable step. Returns the number of photos updated.
    /// Photos that fail are logged and skipped; when none could be written, the first error is thrown.
    @MainActor
    @discardableResult
    public static func setLocations(_ locations: [(LibraryAsset, GeoCoordinate?)], in source: any LibrarySource,
                                    undoManager: UndoManager?, actionName: String = locationActionName) async throws -> Int
    {
        let count = try await write(locations, field: "Location", actionName: actionName, in: source, undoManager: undoManager,
                                    current: { source.location(for: $0) }, write: { try await source.setLocation($0, for: $1) },
                                    again: { try await setLocations($0, in: source, undoManager: nil) })
        logger.notice("Assigned a location to \(count) photos")
        return count
    }

    /// Says these photos, and their JPEG twins, have no location, as one undoable step. Photos without
    /// one are left alone. Returns the number of photos updated.
    @MainActor
    @discardableResult
    public static func removeLocations(of assets: [LibraryAsset], in source: any LibrarySource, undoManager: UndoManager?) async throws -> Int {
        let changes = source.withTwins(assets).filter { source.location(for: $0) != nil }.map { ($0, GeoCoordinate?.none) }
        guard !changes.isEmpty else { return 0 }
        return try await setLocations(changes, in: source, undoManager: undoManager, actionName: removeLocationActionName)
    }

    /// Puts these photos, and their JPEG twins, back where their own files say they were taken, as one
    /// undoable step. Photos the source holds no other location for are left alone. Returns the
    /// number of photos updated.
    @MainActor
    @discardableResult
    public static func revertLocations(of assets: [LibraryAsset], in source: any LibrarySource, undoManager: UndoManager?) async throws -> Int {
        let changes = source.withTwins(assets).compactMap { asset in source.originalLocation(for: asset).map { (asset, $0.coordinate) } }
        guard !changes.isEmpty else { return 0 }
        return try await setLocations(changes, in: source, undoManager: undoManager, actionName: revertLocationActionName)
    }

    /// Writes a value per photo after recording the one in place, so the whole step can be undone;
    /// `again` is what the undo calls with the recorded values, and the redo with the new ones.
    @MainActor
    private static func write<Value: Sendable>(_ values: [(LibraryAsset, Value)], field: String, actionName: String, in source: any LibrarySource,
                                               undoManager: UndoManager?, current: @MainActor (LibraryAsset) -> Value,
                                               write: @MainActor (Value, LibraryAsset) async throws -> Void,
                                               again: @escaping @MainActor ([(LibraryAsset, Value)]) async throws -> Int) async throws -> Int
    {
        var previous: [(LibraryAsset, Value)] = []
        var written: [(LibraryAsset, Value)] = []
        var firstError: (any Error)?
        for (asset, value) in values {
            let before = current(asset)
            do {
                try await write(value, asset)
                previous.append((asset, before))
                written.append((asset, value))
            } catch {
                firstError = firstError ?? error
                logger.error("\(field, privacy: .public) of \(asset.id, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let undoManager, !written.isEmpty {
            register(with: undoManager, restore: previous, redo: written, in: source, actionName: actionName, again: again)
        }
        if written.isEmpty, let firstError {
            throw firstError
        }
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
    private static func register<Value: Sendable>(with undoManager: UndoManager, restore: [(LibraryAsset, Value)], redo: [(LibraryAsset, Value)],
                                                  in source: any LibrarySource, actionName: String,
                                                  again: @escaping @MainActor ([(LibraryAsset, Value)]) async throws -> Int)
    {
        undoManager.registerUndo(withTarget: source as AnyObject) { _ in
            MainActor.assumeIsolated {
                register(with: undoManager, restore: redo, redo: restore, in: source, actionName: actionName, again: again)
            }
            Task { @MainActor in
                _ = try? await again(restore)
            }
        }
        undoManager.setActionName(actionName)
    }
}
