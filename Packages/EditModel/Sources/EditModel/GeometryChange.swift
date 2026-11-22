import Foundation

/// A quarter turn or a mirroring of the photo as it is seen: with its crop and its straightening,
/// which turn or mirror with it. What the Rotate and Flip commands do, in the editor and on the
/// grid's selection.
public enum GeometryChange: String, CaseIterable, Sendable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    /// The name the Edit menu shows after Undo and Redo.
    public var actionName: String {
        switch self {
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate Right"
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
    }
}

public extension Geometry {
    /// The geometry showing the same picture turned or mirrored. The recipe mirrors first, turns,
    /// then straightens and crops, so a change of what is seen is more than a field: the crop frame
    /// moves with the picture, a locked aspect ratio turns with it, and mirroring reverses the turns
    /// and the straightening made before it.
    func applying(_ change: GeometryChange) -> Geometry {
        switch change {
        case .rotateRight:
            Geometry(angle: angle, quarterTurns: quarterTurns + 1, isFlippedHorizontally: isFlippedHorizontally,
                     crop: UnitRect(x: 1 - crop.maxY, y: crop.x, width: crop.height, height: crop.width),
                     aspectRatio: aspectRatio.map { 1 / $0 })
        case .rotateLeft:
            Geometry(angle: angle, quarterTurns: quarterTurns - 1, isFlippedHorizontally: isFlippedHorizontally,
                     crop: UnitRect(x: crop.y, y: 1 - crop.maxX, width: crop.height, height: crop.width),
                     aspectRatio: aspectRatio.map { 1 / $0 })
        case .flipHorizontal:
            Geometry(angle: -angle, quarterTurns: -quarterTurns, isFlippedHorizontally: !isFlippedHorizontally,
                     crop: UnitRect(x: 1 - crop.maxX, y: crop.y, width: crop.width, height: crop.height),
                     aspectRatio: aspectRatio)
        case .flipVertical:
            // Mirrored, then turned upside down.
            Geometry(angle: -angle, quarterTurns: 2 - quarterTurns, isFlippedHorizontally: !isFlippedHorizontally,
                     crop: UnitRect(x: crop.x, y: 1 - crop.maxY, width: crop.width, height: crop.height),
                     aspectRatio: aspectRatio)
        }
    }
}
