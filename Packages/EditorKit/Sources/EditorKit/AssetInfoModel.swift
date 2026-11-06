import CoreGraphics
import CoreImage
import Foundation
import LibraryKit
import Observation
import RenderEngine

/// What the library's Info panel shows about the photo selected in the grid, without opening it in
/// the editor: what the source says about the file, and a histogram.
///
/// The histogram is computed on the photo's thumbnail, so it describes what the grid shows: the
/// saved edit when there is one, the camera's own preview for an untouched RAW. The editor's
/// histogram comes from its own render and can differ slightly.
@Observable
public final class AssetInfoModel {
    /// The photo last asked for; nil while nothing is shown.
    public private(set) var asset: LibraryAsset?
    public private(set) var details: AssetDetails?
    /// Stays on the previous photo's until the new one is computed, rather than blinking empty.
    public private(set) var histogram: Histogram?
    /// True while the source downloads the photo's original to read its header.
    public private(set) var isDownloadingOriginal = false
    /// True when the last download brought nothing back (no connection, typically).
    public private(set) var originalDownloadFailed = false

    /// Long edge of the thumbnail the histogram is computed on, the size `HistogramComputer` samples at.
    static let histogramPixelSize = CGSize(width: 512, height: 512)

    /// Bumped by every `show`: an answer that comes back for an older call is dropped.
    private var generation = 0
    @ObservationIgnored private var download: Task<Void, Never>?

    public init() {}

    /// Shows `asset`, or nothing when it is nil. What the listing knows is there at once, the rest
    /// follows as the source answers. Calling it again, or cancelling the calling task, abandons
    /// the load in flight: the selection moved on.
    public func show(_ asset: LibraryAsset?, in source: any LibrarySource) async {
        generation += 1
        let current = generation
        guard let asset else {
            abandonDownload()
            self.asset = nil
            details = nil
            histogram = nil
            return
        }
        // The same photo again (it was edited, rated): keep what is shown while it is read again.
        if asset.id != self.asset?.id {
            abandonDownload()
            details = AssetDetails(asset)
        }
        self.asset = asset

        let loaded = await source.details(for: asset, allowingDownload: false)
        guard current == generation, !Task.isCancelled else { return }
        details = loaded

        let thumbnail = await source.thumbnail(for: asset, pixelSize: Self.histogramPixelSize)
        guard current == generation, !Task.isCancelled else { return }
        guard let thumbnail else {
            histogram = nil
            return
        }
        let computed = await Task.detached(priority: .utility) { HistogramComputer.compute(CIImage(cgImage: thumbnail)) }.value
        guard current == generation, !Task.isCancelled else { return }
        histogram = computed
    }

    /// Downloads the original of the photo shown, at the user's request, to complete details that
    /// came back with `isOriginalInCloud`. Moving to another photo abandons the download.
    public func downloadOriginal(in source: any LibrarySource) {
        guard let asset, download == nil else { return }
        isDownloadingOriginal = true
        originalDownloadFailed = false
        download = Task { [weak self] in
            let loaded = await source.details(for: asset, allowingDownload: true)
            guard let self, !Task.isCancelled, self.asset?.id == asset.id else { return }
            details = loaded
            originalDownloadFailed = loaded.isOriginalInCloud
            isDownloadingOriginal = false
            download = nil
        }
    }

    /// Waits for the download in flight; for tests.
    func waitForDownload() async {
        await download?.value
    }

    private func abandonDownload() {
        download?.cancel()
        download = nil
        isDownloadingOriginal = false
        originalDownloadFailed = false
    }

    /// The details to show for `asset`: the loaded ones once they are its own, what the listing knows
    /// until then (the frame between a click and the start of the load).
    public func details(for asset: LibraryAsset) -> AssetDetails {
        if self.asset?.id == asset.id, let details {
            return details
        }
        return AssetDetails(asset)
    }
}
