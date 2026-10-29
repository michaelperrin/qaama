import Foundation

/// The photos of a source as a random-access collection, so a lazy grid materializes only the rows it
/// shows. A folder wraps an array; the Photos library computes each element from its fetch result.
public struct AssetCollection: @MainActor RandomAccessCollection {
    public typealias Element = LibraryAsset
    public typealias Index = Int

    public let startIndex = 0
    public let endIndex: Int
    private let element: (Int) -> LibraryAsset

    public init(count: Int, element: @escaping (Int) -> LibraryAsset) {
        endIndex = count
        self.element = element
    }

    public init(_ assets: [LibraryAsset]) {
        self.init(count: assets.count) { assets[$0] }
    }

    public static let empty = AssetCollection([])

    public subscript(position: Int) -> LibraryAsset {
        element(position)
    }
}
