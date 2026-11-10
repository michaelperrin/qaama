import CoreGraphics
import Foundation
import ImageIOKit
import Observation

/// An in-memory source with generated images, for SwiftUI previews and tests. Stores decisions and
/// edits in memory; supports every capability so every control can be previewed.
@Observable
public final class SampleLibrarySource: LibrarySource {
    public let displayName: String
    public private(set) var assets: AssetCollection = .empty
    public private(set) var timeline: DateTimeline?
    public private(set) var lastLoadDuration: Duration?
    public var capabilities: Set<LibraryCapability> = [.rating, .flag, .keywords, .captureDate]
    public var queryCapabilities: Set<QueryCapability> {
        [.sortByRating, .sortByFileName, .rating, .flag, .edited, .favorite, .search]
    }

    public var query = LibraryQuery.default {
        didSet { refresh() }
    }

    private var byID: [String: LibraryAsset] = [:]
    private var images: [String: CGImage] = [:]
    private var recipes: [String: Data] = [:]
    /// The dates the photos were "shot" at, to go back to when a correction is removed.
    private var ownDates: [String: Date] = [:]

    /// `pairsFirstTwo` makes the first two photos a RAW + JPEG pair stored as two photos. The photos
    /// are "shot" `daysApart` from one another, the first one being the newest: a day by default, more
    /// to spread them over several months.
    public init(displayName: String = "Sample", count: Int = 12, pairsFirstTwo: Bool = false, daysApart: Double = 1) {
        self.displayName = displayName
        var list: [LibraryAsset] = []
        for index in 0 ..< count {
            let id = "sample-\(index)"
            let landscape = index % 3 != 0
            let size = landscape ? (width: 600, height: 400) : (width: 400, height: 600)
            var asset = LibraryAsset(
                id: id, pixelWidth: size.width, pixelHeight: size.height,
                creationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * daysApart * 86400),
                isFavorite: index % 5 == 0, rating: index % 6,
                flag: index % 7 == 0 ? .picked : (index % 7 == 1 ? .rejected : .none),
                keywords: index % 2 == 0 ? ["sample", "even"] : [],
                modificationDate: .now, hasEdit: index % 4 == 0, isRAW: pairsFirstTwo && index == 0,
                pairedAssetID: pairsFirstTwo && index < 2 && count >= 2 ? "sample-\(1 - index)" : nil
            )
            asset.rating = index % 6
            list.append(asset)
            byID[id] = asset
            ownDates[id] = asset.creationDate
            images[id] = Self.makeImage(width: size.width, height: size.height, hue: Double(index) / Double(max(count, 1)))
        }
        refresh()
        lastLoadDuration = .milliseconds(3)
    }

    public func asset(id: LibraryAsset.ID) -> LibraryAsset? {
        byID[id]
    }

    public func load() async {}

    public func thumbnail(for asset: LibraryAsset, pixelSize _: CGSize, fit _: ThumbnailFit) async -> CGImage? {
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

    public func captureDate(for asset: LibraryAsset) -> Date? {
        byID[asset.id]?.creationDate
    }

    public func setCaptureDate(_ date: Date?, for asset: LibraryAsset) async throws {
        guard capabilities.contains(.captureDate) else { throw LibrarySourceError.unsupported(.captureDate) }
        let own = ownDates[asset.id]
        update(asset.id) { $0.creationDate = date ?? own }
    }

    /// Photos whose original plays at being in iCloud: their details come without the camera until
    /// a download is allowed, which brings the original "back" for good.
    public var cloudOnlyIDs: Set<LibraryAsset.ID> = []

    /// A made-up camera, so previews show every row of the Info panel.
    public func details(for asset: LibraryAsset, allowingDownload: Bool) async -> AssetDetails {
        if cloudOnlyIDs.contains(asset.id) {
            guard allowingDownload else {
                var partial = AssetDetails(asset)
                partial.fileName = "\(asset.id).jpg"
                partial.isOriginalInCloud = true
                return partial
            }
            cloudOnlyIDs.remove(asset.id)
        }
        return AssetDetails(fileName: "\(asset.id).jpg", metadata: ImageMetadata(
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, captureDate: captureDate(for: asset),
            cameraMake: "Qaama", cameraModel: "Sample", lens: "35mm F2", iso: 200, exposureTime: 1 / 250, aperture: 2.8, focalLength: 35,
            // Every other photo was "taken" in Paris, so previews show the panel with and without a map.
            location: (Int(asset.id.dropFirst("sample-".count)) ?? 0).isMultiple(of: 2) ? GeoCoordinate(latitude: 48.8584, longitude: 2.2945) : nil
        ))
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
        timeline = query.sort == .captureDate ? DateTimeline(dates: matching.lazy.map(\.creationDate)) : nil
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
