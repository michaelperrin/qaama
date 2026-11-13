import Foundation

/// The maps of a window, one per library shown on a map: going to another library and back finds
/// the map as it was left (photos, thumbnails, place and zoom) instead of loading it again.
///
/// A model lives as long as its library; those of libraries that are gone are dropped when another
/// is asked for.
public final class PhotoMapModels {
    private struct Entry {
        weak var source: (any LibrarySource)?
        let model: PhotoMapModel
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    public init() {}

    public func model(for source: any LibrarySource) -> PhotoMapModel {
        let key = ObjectIdentifier(source)
        // The identifier of a library that is gone may be given to another one.
        if let entry = entries[key], entry.source === source {
            return entry.model
        }
        entries = entries.filter { $0.value.source != nil }
        let model = PhotoMapModel()
        entries[key] = Entry(source: source, model: model)
        return model
    }
}
