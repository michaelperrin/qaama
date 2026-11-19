import Foundation
import ImageIOKit
import LibraryKit
import Observation

/// Assigning a location to the photos shown in an Info panel, without its view: the location they
/// share, the search for a place by name (`places`), and the writing of a place picked from the
/// results, put down on the map or dragged there, as one undoable step.
///
/// The JPEG twin of a RAW + JPEG pair stored as two photos goes with its RAW, as for a corrected date.
@Observable
public final class LocationEditModel {
    /// The photos shown.
    public private(set) var assets: [LibraryAsset] = []
    /// Where every photo shown was taken, when they all say the same place; nil otherwise.
    public private(set) var location: GeoCoordinate?
    /// True when the photos shown say different places, or only some say one.
    public private(set) var isMixed = false
    /// True when the source holds a location of its own over what the file of one of the photos says:
    /// there is an original location to go back to.
    public private(set) var canRevert = false

    /// True when one of the photos shown has a location to remove.
    public var canRemove: Bool {
        location != nil || isMixed
    }

    /// True while the panel offers to search and to move the pin; ends with another selection.
    public var isEditing = false {
        didSet {
            if !isEditing {
                places.query = ""
            }
        }
    }

    /// The search for the place to assign: its field, its results and their highlight.
    public let places: PlaceSearchModel
    /// What went wrong with the last write, else with the last search, to show as is.
    public var errorMessage: String? {
        writeError ?? places.errorMessage
    }

    private var writeError: String?
    /// Where the map should center: on another photo's place, or on a place picked from the search.
    /// Not on a pin put down or dragged on the map, which is in view already: the map mustn't move
    /// under the pointer.
    public private(set) var focus: GeoCoordinate?
    /// The last place assigned in this panel: a photo without a location opens the map there, as the
    /// next photo of a series was often taken nearby.
    public private(set) var lastAssigned: GeoCoordinate?

    @ObservationIgnored private var source: (any LibrarySource)?

    /// `searchDelay` and `search` are the place search's (see `PlaceSearchModel`).
    public init(searchDelay: Duration = .milliseconds(300), search: @escaping PlaceSearchModel.Search) {
        places = PlaceSearchModel(delay: searchDelay, search: search)
    }

    // MARK: - Showing

    /// Shows the location of these photos. Another selection leaves the editing; the same photos,
    /// handed in again after a write or an undo, keep it.
    public func show(_ assets: [LibraryAsset], in source: any LibrarySource) {
        let isAnotherSelection = Set(assets.map(\.id)) != Set(self.assets.map(\.id))
        if isAnotherSelection {
            isEditing = false
            writeError = nil
        }
        self.source = source
        self.assets = assets
        let locations = assets.map { source.location(for: $0) }
        let first = locations.first ?? nil
        let shared = locations.allSatisfy { Self.samePlace($0, first) }
        location = shared ? first : nil
        isMixed = !shared
        canRevert = source.withTwins(assets).contains { source.originalLocation(for: $0) != nil }
        if isAnotherSelection {
            focus = startingPoint
        }
        places.near = startingPoint
    }

    private static func samePlace(_ one: GeoCoordinate?, _ other: GeoCoordinate?) -> Bool {
        switch (one, other) {
        case (nil, nil): true
        case let (one?, other?): one.isAlmostEqual(to: other)
        default: false
        }
    }

    /// Where the map opens when editing photos that say no single place: the last place assigned here.
    public var startingPoint: GeoCoordinate? {
        location ?? lastAssigned
    }

    // MARK: - Assigning

    /// Gives every photo shown, and their twins, this location, in one undoable step. Photos already
    /// there are left alone; nothing is written, nor registered, when all are.
    public func assign(_ coordinate: GeoCoordinate, undoManager: UndoManager?) async {
        guard let source else { return }
        let changes = source.withTwins(assets).compactMap { asset -> (LibraryAsset, GeoCoordinate?)? in
            if let current = source.location(for: asset), current.isAlmostEqual(to: coordinate) {
                return nil
            }
            return (asset, coordinate)
        }
        lastAssigned = coordinate
        places.near = coordinate
        guard !changes.isEmpty else { return }
        // Shown at once: Photos tells of the change a moment later.
        location = coordinate
        isMixed = false
        do {
            try await MetadataEditing.setLocations(changes, in: source, undoManager: undoManager)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
            show(assets, in: source)
        }
    }

    /// Says the photos shown, and their twins, have no location, in one undoable step.
    public func remove(undoManager: UndoManager?) async {
        await write { source in try await MetadataEditing.removeLocations(of: assets, in: source, undoManager: undoManager) }
    }

    /// Puts the photos shown, and their twins, back where their files say they were taken, in one
    /// undoable step; the map then frames that place.
    public func revert(undoManager: UndoManager?) async {
        await write { source in try await MetadataEditing.revertLocations(of: assets, in: source, undoManager: undoManager) }
        focus = location
    }

    /// Runs a write, then shows what the source holds now.
    private func write(_ work: @MainActor (any LibrarySource) async throws -> Int) async {
        guard let source else { return }
        do {
            _ = try await work(source)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
        show(assets, in: source)
    }

    /// Assigns a place found by the search, and closes the search: its results are done with.
    public func pick(_ suggestion: PlaceSuggestion, undoManager: UndoManager?) async {
        places.query = ""
        focus = suggestion.coordinate
        await assign(suggestion.coordinate, undoManager: undoManager)
    }

    /// Picks the highlighted result, as Return does.
    public func pickHighlighted(undoManager: UndoManager?) async {
        guard let suggestion = places.highlighted else { return }
        await pick(suggestion, undoManager: undoManager)
    }
}

extension LibrarySource {
    /// The photos with the JPEG twin of each RAW + JPEG pair stored as two photos, twins after the
    /// photos and each once: a correction written to one half alone would part the pair.
    func withTwins(_ assets: [LibraryAsset]) -> [LibraryAsset] {
        var seen = Set(assets.map(\.id))
        var all = assets
        for asset in assets {
            if let twinID = asset.pairedAssetID, seen.insert(twinID).inserted, let twin = self.asset(id: twinID) {
                all.append(twin)
            }
        }
        return all
    }
}
