import Foundation

/// Scene classes the segmentation model can isolate, with the labels it uses and the names shown.
public enum SceneClasses {
    public struct Entry: Hashable, Sendable {
        public let label: String
        public let displayName: String
    }

    public static let sky = Entry(label: "sky (other)", displayName: "Sky")

    /// Curated subset of the model's classes that make sense as masks for photo editing.
    public static let all: [Entry] = [
        Entry(label: "grass", displayName: "Grass"),
        Entry(label: "tree", displayName: "Trees"),
        Entry(label: "mountain", displayName: "Mountains"),
        Entry(label: "sea", displayName: "Sea"),
        Entry(label: "river", displayName: "River"),
        Entry(label: "water (other)", displayName: "Water"),
        Entry(label: "sand", displayName: "Sand"),
        Entry(label: "snow", displayName: "Snow"),
        Entry(label: "rock", displayName: "Rocks"),
        Entry(label: "dirt", displayName: "Ground"),
        Entry(label: "road", displayName: "Road"),
        Entry(label: "pavement", displayName: "Pavement"),
        Entry(label: "building (other)", displayName: "Buildings"),
        Entry(label: "house", displayName: "Houses"),
        Entry(label: "wall (other)", displayName: "Walls"),
        Entry(label: "floor (other)", displayName: "Floor"),
    ]

    public static func displayName(for label: String) -> String {
        if label == sky.label {
            return sky.displayName
        }
        return all.first { $0.label == label }?.displayName ?? label.capitalized
    }
}
