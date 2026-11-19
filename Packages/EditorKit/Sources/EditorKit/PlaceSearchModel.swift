import Foundation
import ImageIOKit
import Observation

/// A place a search by name found: what the list of results shows, and where it is.
public nonisolated struct PlaceSuggestion: Identifiable, Hashable, Sendable {
    public let id = UUID()
    /// The place's own name ("Étretat", "Tour Eiffel").
    public var title: String
    /// Where it is, to tell places of the same name apart ("Seine-Maritime, France").
    public var subtitle: String
    public var coordinate: GeoCoordinate

    public init(title: String, subtitle: String, coordinate: GeoCoordinate) {
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
    }
}

/// The search for a place by name, without its view: what is typed, the results a short pause after
/// the last keystroke, and the one the arrow keys highlight for Return to pick. Shared by what
/// assigns a location to photos (`LocationEditModel`) and what filters them by place.
@Observable
public final class PlaceSearchModel {
    /// Finds places by name, closest to `near` first when it is given. Handed in (the app's goes to
    /// Apple's service through MapKit), so this stays free of MapKit and testable. Throws when it
    /// couldn't search (no network, too many requests).
    public typealias Search = @MainActor (_ text: String, _ near: GeoCoordinate?) async throws -> [PlaceSuggestion]

    /// What is typed in the search field. Each change starts a new search after a short pause;
    /// emptying it drops the results.
    public var query = "" {
        didSet {
            if query != oldValue {
                scheduleSearch()
            }
        }
    }

    /// What the last search found, best match first.
    public private(set) var suggestions: [PlaceSuggestion] = []
    /// The result Return picks, moved by the arrow keys.
    public private(set) var highlightedID: PlaceSuggestion.ID?
    public private(set) var isSearching = false
    /// What went wrong with the last search, to show as is.
    public private(set) var errorMessage: String?
    /// Results near this place come first, when it is set.
    @ObservationIgnored public var near: GeoCoordinate?

    @ObservationIgnored private let search: Search
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// `delay` is the pause after a keystroke before searching: the service limits how often it is
    /// asked, and a word half typed is seldom the place meant.
    public init(delay: Duration = .milliseconds(300), search: @escaping Search) {
        self.delay = delay
        self.search = search
    }

    /// True while something is typed: there are results, or a word to say about them, to show.
    public var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The result Return picks.
    public var highlighted: PlaceSuggestion? {
        suggestions.first { $0.id == highlightedID }
    }

    /// Moves the highlight through the results, as the arrow keys do, staying within them.
    public func moveHighlight(by offset: Int) {
        guard !suggestions.isEmpty else { return }
        let current = suggestions.firstIndex { $0.id == highlightedID } ?? -1
        let next = min(max(current + offset, 0), suggestions.count - 1)
        highlightedID = suggestions[next].id
    }

    private func scheduleSearch() {
        pending?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            suggestions = []
            highlightedID = nil
            isSearching = false
            errorMessage = nil
            return
        }
        isSearching = true
        pending = Task { [delay, search, near] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            do {
                let found = try await search(text, near)
                guard !Task.isCancelled else { return }
                suggestions = found
                highlightedID = found.first?.id
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                suggestions = []
                highlightedID = nil
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }

    /// Waits for the search under way, for tests.
    func settled() async {
        await pending?.value
    }
}
