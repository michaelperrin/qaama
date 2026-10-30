import CoreGraphics
import Foundation
import Observation

/// An in-memory source with generated images, for SwiftUI previews and tests. Stores decisions and
/// edits in memory; supports every capability so every control can be previewed.
@Observable
public final class SampleLibrarySource: LibrarySource {
    public let displayName: String
    public private(set) var assets: AssetCollection = .empty
    public private(set) var lastLoadDuration: Duration?
    public var capabilities: Set<LibraryCapability> = [.rating, .flag, .keywords]
    public var queryCapabilities: Set<QueryCapability> {
        [.sortByRating, .sortByFileName, .rating, .flag, .edited, .favorite, .search]
    }

    public var query = LibraryQuery.default {
        didSet { refresh() }
    }

    private var byID: [String: LibraryAsset] = [:]
    private var images: [String: CGImage] = [:]
    private var recipes: [String: Data] = [:]

    public init(displayName: String = "Sample", count: Int = 12) {
        self.displayName = displayName
        var list: [LibraryAsset] = []
        for index in 0 ..< count {
            let id = "sample-\(index)"
            let landscape = index % 3 != 0
            let size = landscape ? (width: 600, height: 400) : (width: 400, height: 600)
            var asset = LibraryAsset(
                id: id, pixelWidth: size.width, pixelHeight: size.height,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 86400),
                isFavorite: index % 5 == 0, rating: index % 6,
                flag: index % 7 == 0 ? .picked : (index % 7 == 1 ? .rejected : .none),
                keywords: index % 2 == 0 ? ["sample", "even"] : [],
                modificationDate: .now, hasEdit: index % 4 == 0
            )
            asset.rating = index % 6
            list.append(asset)
            byID[id] = asset
            images[id] = Self.makeImage(width: size.width, height: size.height, hue: Double(index) / Double(max(count, 1)))
        }
        refresh()
        lastLoadDuration = .milliseconds(3)
    }

    public func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        byID[id]
    }

    public func load() async {}

    public func thumbnail(for asset: LibraryAsset, pixelSize _: CGSize) async -> CGImage? {
        images[asset.id]
    }

    public func fullSizeImage(for asset: LibraryAsset) async -> CGImage? {
        images[asset.id]
    }

    public func setRating(_ rating: Int, for asset: LibraryAsset) async throws {
        update(asset.id) { $0.rating = rating }
    }

    public func setFlag(_ flag: ItemFlag, for asset: LibraryAsset) async throws {
        update(asset.id) { $0.flag = flag }
    }

    public func setKeywords(_ keywords: [String], for asset: LibraryAsset) async throws {
        update(asset.id) { $0.keywords = keywords }
    }

    public func editingInput(for asset: LibraryAsset) async throws -> EditingInput {
        EditingInput(image: images[asset.id], recipeData: recipes[asset.id])
    }

    public func saveEdit(_ output: EditingOutput, for asset: LibraryAsset) async throws {
        recipes[asset.id] = output.isReset ? nil : output.recipeData
        update(asset.id) { $0.hasEdit = !output.isReset }
    }

    private func update(_ id: String, _ change: (inout LibraryAsset) -> Void) {
        guard var asset = byID[id] else { return }
        change(&asset)
        byID[id] = asset
        refresh()
    }

    private func refresh() {
        let matching = byID.values.filter { query.matches($0) }.sorted(by: query.areInIncreasingOrder)
        assets = AssetCollection(matching)
    }

    /// A two-tone gradient, enough to tell thumbnails apart.
    private static func makeImage(width: Int, height: Int, hue: Double) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let top = CGColor(red: 0.2 + 0.6 * hue, green: 0.4, blue: 0.9 - 0.6 * hue, alpha: 1)
        let bottom = CGColor(red: 0.1, green: 0.3 + 0.4 * hue, blue: 0.2, alpha: 1)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        }
        return context.makeImage()
    }
}
