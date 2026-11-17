/// The way back from places reached through a link rather than chosen in the sidebar: each visit
/// keeps where it was made from and how things were left there, and going back retraces them, the
/// last one first.
///
/// The trail only holds while the user follows it: once they go anywhere else by other means, there
/// is nothing to go back to, and the trail is forgotten.
public nonisolated struct VisitTrail<Location: Hashable, Place> {
    private struct Visit {
        let origin: Location
        let place: Place
        let destination: Location
    }

    private var visits: [Visit] = []

    public init() {}

    /// How many steps back the trail holds.
    public var count: Int {
        visits.count
    }

    /// Notes that `destination` is being shown from `origin`, which was left as `place` describes.
    public mutating func visit(_ destination: Location, from origin: Location, leaving place: Place) {
        moved(to: origin)
        visits.append(Visit(origin: origin, place: place, destination: destination))
    }

    /// Where `location` was reached from, when it is the end of the trail; nil when it was reached
    /// another way.
    public func origin(of location: Location) -> Location? {
        visits.last.flatMap { $0.destination == location ? $0.origin : nil }
    }

    /// Leaves `location` for where it was reached from, and tells how that place was left; nil when
    /// `location` isn't the end of the trail.
    public mutating func goBack(from location: Location) -> (origin: Location, place: Place)? {
        guard let last = visits.last, last.destination == location else { return nil }
        visits.removeLast()
        return (last.origin, last.place)
    }

    /// Tells where the user is now. Anywhere but at the end of the trail, they left it.
    public mutating func moved(to location: Location) {
        if let last = visits.last, last.destination != location {
            visits.removeAll()
        }
    }
}
