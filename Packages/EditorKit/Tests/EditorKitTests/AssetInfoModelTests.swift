@testable import EditorKit
import Foundation
import ImageIOKit
import LibraryKit
import Testing

@MainActor
struct AssetInfoModelTests {
    @Test func showsTheDetailsAndAHistogramOfThePhoto() async throws {
        let source = SampleLibrarySource(count: 3)
        let asset = try #require(source.assets.first)
        let model = AssetInfoModel()

        await model.show(asset, in: source)
        #expect(model.asset == asset)
        #expect(model.details?.fileName == "\(asset.id).jpg")
        #expect(model.details?.metadata?.pixelWidth == asset.pixelWidth)
        #expect(model.details?.metadata?.cameraModel == "Sample")
        let histogram = try #require(model.histogram)
        #expect(histogram.red.count == 256 && histogram.luminance.contains { $0 > 0 })
    }

    @Test func showingNothingClearsThePanel() async {
        let source = SampleLibrarySource(count: 2)
        let model = AssetInfoModel()
        await model.show(source.assets[0], in: source)
        #expect(model.asset != nil)

        await model.show(nil, in: source)
        #expect(model.asset == nil && model.details == nil && model.histogram == nil)
    }

    @Test func aPhotoNotLoadedYetShowsWhatTheListingKnows() async {
        let source = SampleLibrarySource(count: 2)
        let first = source.assets[0]
        let second = source.assets[1]
        let model = AssetInfoModel()
        #expect(model.details(for: first) == AssetDetails(first))

        await model.show(first, in: source)
        #expect(model.details(for: first).fileName == "\(first.id).jpg")
        // Selected but not loaded yet: never the previous photo's details under its name.
        #expect(model.details(for: second) == AssetDetails(second))
    }

    @Test func anAbandonedLoadLeavesThePanelToTheNextOne() async {
        let source = SampleLibrarySource(count: 2)
        let first = source.assets[0]
        let second = source.assets[1]
        let model = AssetInfoModel()

        // The selection moves on before the first photo's details came back.
        let abandoned = Task { await model.show(first, in: source) }
        abandoned.cancel()
        await abandoned.value
        await model.show(second, in: source)
        #expect(model.asset == second)
        #expect(model.details?.fileName == "\(second.id).jpg")
        #expect(model.histogram != nil)
    }

    @Test func anOriginalInCloudIsDownloadedOnlyOnRequest() async {
        let source = SampleLibrarySource(count: 2)
        let asset = source.assets[0]
        source.cloudOnlyIDs = [asset.id]
        let model = AssetInfoModel()

        await model.show(asset, in: source)
        #expect(model.details?.isOriginalInCloud == true)
        #expect(model.details?.metadata?.cameraModel == nil && model.details?.metadata?.pixelWidth == asset.pixelWidth)
        #expect(!model.isDownloadingOriginal)

        model.downloadOriginal(in: source)
        #expect(model.isDownloadingOriginal)
        await model.waitForDownload()
        #expect(!model.isDownloadingOriginal && !model.originalDownloadFailed)
        #expect(model.details?.isOriginalInCloud == false)
        #expect(model.details?.metadata?.cameraModel == "Sample")
    }

    @Test func movingToAnotherPhotoAbandonsTheDownload() async {
        let source = SampleLibrarySource(count: 2)
        let first = source.assets[0]
        let second = source.assets[1]
        source.cloudOnlyIDs = [first.id]
        let model = AssetInfoModel()
        await model.show(first, in: source)

        model.downloadOriginal(in: source)
        await model.show(second, in: source)
        #expect(!model.isDownloadingOriginal)
        #expect(model.asset == second && model.details?.fileName == "\(second.id).jpg")
        // Whatever the abandoned download brings back later stays out of the panel.
        await Task.yield()
        #expect(model.details?.fileName == "\(second.id).jpg" && model.details?.isOriginalInCloud == false)
    }

    // MARK: - Several photos

    @Test func severalPhotosShowWhatTheyShare() async throws {
        let source = SampleLibrarySource(count: 6)
        // Photos 0, 2 and 4 carry the keywords "sample" and "even"; ratings are 0, 2 and 4.
        let assets = [source.assets[0], source.assets[2], source.assets[4]]
        let model = AssetInfoModel()

        await model.show(assets, in: source)
        #expect(model.asset == nil && model.details == nil && model.histogram == nil, "one photo's panel is not shown for several")
        #expect(!model.isSummarizing)
        let summary = try #require(model.summary)
        #expect(summary.camera == .value("Qaama Sample") && summary.lens == .value("35mm F2"))
        #expect(summary.size == .mixed, "portrait and landscape photos")
        #expect(summary.unreadCount == 0)
        #expect(model.keywords == ["sample", "even"])
        #expect(model.rating == nil, "ratings differ")
        #expect(model.flag == nil)

        await model.show([], in: source)
        #expect(model.assets.isEmpty && model.summary == nil && model.keywords.isEmpty)
    }

    @Test func aDecisionGoesToEveryPhotoAndIsOneUndoableStep() async throws {
        let source = SampleLibrarySource(count: 6)
        let assets = [source.assets[1], source.assets[2], source.assets[3]]
        let before = assets.map(\.rating)
        let model = AssetInfoModel()
        await model.show(assets, in: source)
        let manager = UndoManager()
        manager.groupsByEvent = false

        manager.beginUndoGrouping()
        await model.setRating(5, in: source, undoManager: manager)
        manager.endUndoGrouping()
        #expect(model.rating == 5 && model.errorMessage == nil)
        #expect(assets.allSatisfy { source.asset(id: $0.id)?.rating == 5 })
        #expect(manager.canUndo && manager.undoActionName == "Rating")

        manager.undo()
        for _ in 0 ..< 200 where assets.map({ source.asset(id: $0.id)?.rating }) != before {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(assets.map { source.asset(id: $0.id)?.rating } == before)

        await model.setFlag(.rejected, in: source, undoManager: nil)
        #expect(model.flag == .rejected && assets.allSatisfy { source.asset(id: $0.id)?.flag == .rejected })
    }

    @Test func keywordsEditedForSeveralPhotosOnlyTouchTheSharedOnes() async throws {
        let source = SampleLibrarySource(count: 6)
        let first = source.assets[0], second = source.assets[2]
        try await source.setKeywords(["sample", "even", "lapland"], for: first)
        let assets = try [#require(source.asset(id: first.id)), second]
        let model = AssetInfoModel()
        await model.show(assets, in: source)
        #expect(model.keywords == ["sample", "even"], "\"lapland\" belongs to one photo only")

        // "even" is removed from the shared keywords, "winter" added.
        await model.setKeywords(["sample", "winter"], in: source, undoManager: nil)
        #expect(model.keywords == ["sample", "winter"])
        let firstNow = try #require(source.asset(id: first.id)), secondNow = try #require(source.asset(id: second.id))
        #expect(await source.keywords(for: firstNow) == ["sample", "lapland", "winter"])
        #expect(await source.keywords(for: secondNow) == ["sample", "winter"])

        // Nothing changed: nothing written.
        let manager = UndoManager()
        await model.setKeywords(["sample", "winter"], in: source, undoManager: manager)
        #expect(!manager.canUndo)
    }

    @Test func showingTheSamePhotosAgainDoesNotReadTheirFilesAgain() async {
        let source = SampleLibrarySource(count: 4)
        source.cloudOnlyIDs = [source.assets[0].id]
        let assets = [source.assets[0], source.assets[1]]
        let model = AssetInfoModel()
        await model.show(assets, in: source)
        #expect(model.summary?.unreadCount == 1)

        // The original "comes back", then a rating changes: what was read for these photos is kept.
        source.cloudOnlyIDs = []
        var rated = assets
        rated[1].rating = 5
        await model.show(rated, in: source)
        #expect(model.summary?.unreadCount == 1 && model.rating == nil)

        // Another selection starts from scratch.
        await model.show([assets[0], source.assets[2]], in: source)
        #expect(model.summary?.unreadCount == 0)
    }
}

struct InfoSummaryTests {
    private func details(camera: String?, lens: String? = nil, width: Int = 6000, date: Date? = nil, inCloud: Bool = false) -> AssetDetails {
        AssetDetails(metadata: ImageMetadata(pixelWidth: width, pixelHeight: 4000, captureDate: date, cameraModel: camera, lens: lens, iso: 200,
                                             exposureTime: 0.004, aperture: 2.8, focalLength: 35),
                     isOriginalInCloud: inCloud)
    }

    @Test func onePhotoShowsWhatItsFileSays() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = InfoSummary([details(camera: "X-T30", lens: "XF35mm", date: date)])
        #expect(summary.camera == .value("X-T30") && summary.lens == .value("XF35mm"))
        #expect(summary.size == .value("6000 × 4000"))
        #expect(summary.captured == .value(date.formatted(date: .abbreviated, time: .shortened)))
        #expect(summary.exposure != .none && summary.exposure != .mixed)
        #expect(!summary.isEmpty && InfoSummary([]).isEmpty && InfoSummary(metadata: nil).isEmpty)
    }

    @Test func severalPhotosShareAValueOrAreMixed() {
        let summary = InfoSummary([details(camera: "X-T30", lens: "XF35mm"), details(camera: "X-T30", lens: "XF16-80mm", width: 4000)])
        #expect(summary.camera == .value("X-T30"))
        #expect(summary.lens == .mixed && summary.size == .mixed)
        // Only one of the two says which lens: that is not something they share.
        #expect(InfoSummary([details(camera: "X-T30", lens: "XF35mm"), details(camera: "X-T30")]).lens == .mixed)
        // Neither says: the line is left out.
        #expect(InfoSummary([details(camera: nil), details(camera: nil)]).camera == .none)
    }

    @Test func aPhotoWhoseOriginalIsAwayIsUnknownNotDifferent() {
        let away = AssetDetails(metadata: ImageMetadata(pixelWidth: 6000, pixelHeight: 4000), isOriginalInCloud: true)
        let summary = InfoSummary([details(camera: "X-T30", lens: "XF35mm"), away])
        #expect(summary.camera == .value("X-T30") && summary.lens == .value("XF35mm"))
        #expect(summary.unreadCount == 1)
        #expect(summary.size == .value("6000 × 4000"), "the library knows its size")
    }

    @Test func datesShowAsOneDateOrASpan() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        let morning = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(InfoSummary.captured([], calendar: calendar) == .none)
        #expect(InfoSummary.captured([morning, morning], calendar: calendar) == .value(morning.formatted(date: .abbreviated, time: .shortened)))
        let later = morning.addingTimeInterval(1800), nextWeek = morning.addingTimeInterval(7 * 86400)
        let day = morning.formatted(date: .abbreviated, time: .omitted)
        let sameDay = "\(day), \(morning.formatted(date: .omitted, time: .shortened)) – \(later.formatted(date: .omitted, time: .shortened))"
        #expect(InfoSummary.captured([later, morning], calendar: calendar) == .value(sameDay))
        #expect(InfoSummary.captured([morning, nextWeek, later], calendar: calendar)
            == .value("\(day) – \(nextWeek.formatted(date: .abbreviated, time: .omitted))"))
    }
}
