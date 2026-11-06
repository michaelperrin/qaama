import CoreGraphics
@testable import EditorKit
import Foundation
import ImageIO
import ImageIOKit
import LibraryKit
import RenderEngine
import Testing
import UniformTypeIdentifiers

struct DateAdjustmentTests {
    private var paris: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test func shiftsMoveLaterOrEarlierByDaysHoursAndMinutes() {
        let shot = date("2026-10-29T13:03:12Z")
        #expect(DateShift(hours: 1).applied(to: shot, calendar: paris) == date("2026-10-29T14:03:12Z"))
        #expect(DateShift(days: 1, hours: 2, minutes: 30, direction: .earlier).applied(to: shot, calendar: paris) == date("2026-10-28T10:33:12Z"))
        #expect(DateShift().isZero && !DateShift(minutes: 1).isZero)
        #expect(DateShift(days: -3).days == 0, "the direction says earlier, not a negative amount")
    }

    @Test func aDayLaterIsTheSameTimeOfDayAcrossADaylightSavingChange() {
        // Paris leaves summer time in the night of 24 to 25 October 2026: that day lasts 25 hours.
        let before = date("2026-10-24T10:00:00Z") // noon in Paris
        #expect(DateShift(days: 1).applied(to: before, calendar: paris) == date("2026-10-25T11:00:00Z"), "still noon in Paris")
        #expect(DateShift(hours: 24).applied(to: before, calendar: paris) == date("2026-10-25T10:00:00Z"), "24 elapsed hours")
    }

    @Test func yearsAndMonthsFollowTheCalendar() {
        // A camera reset to 1 January 2020 at noon, when it really was 6 November 2026, 15:30, in Paris.
        let reset = date("2020-01-01T11:00:00Z")
        let shift = DateShift(years: 6, months: 10, days: 5, hours: 3, minutes: 30)
        #expect(shift.applied(to: reset, calendar: paris) == date("2026-11-06T14:30:00Z"))
        #expect(!DateShift(years: 1).isZero && !DateShift(months: 1).isZero)
        // A month after 31 January is the last day of February, and a year back from 29 February is the 28th.
        #expect(DateShift(months: 1).applied(to: date("2026-01-31T11:00:00Z"), calendar: paris) == date("2026-02-28T11:00:00Z"))
        #expect(DateShift(years: 1, direction: .earlier).applied(to: date("2024-02-29T11:00:00Z"), calendar: paris) == date("2023-02-28T11:00:00Z"))
    }

    @Test func aShiftCanBeDerivedFromTheRealDateOfOnePhoto() {
        // The reset camera again: it said 1 January 2020 at noon when it was 6 November 2026, 15:30.
        let reset = date("2020-01-01T11:00:00Z"), real = date("2026-11-06T14:30:00Z")
        let forward = DateShift(from: reset, to: real, calendar: paris)
        #expect(forward == DateShift(years: 6, months: 10, days: 5, hours: 3, minutes: 30))
        #expect(forward.applied(to: reset, calendar: paris) == real)
        // The other way round, and nothing at all.
        let backward = DateShift(from: real, to: reset, calendar: paris)
        #expect(backward.direction == .earlier && backward.applied(to: real, calendar: paris) == reset)
        #expect(DateShift(from: reset, to: reset, calendar: paris).isZero)
        #expect(DateShift(from: reset, to: reset.addingTimeInterval(3600), calendar: paris) == DateShift(hours: 1))

        // Around month ends the calendar isn't symmetric: whatever the spelling, the shift lands on the date asked for.
        let pairs = [("2026-03-31T10:00:00Z", "2026-02-28T09:15:00Z"), ("2024-02-29T10:00:00Z", "2023-02-28T10:00:00Z"),
                     ("2026-01-31T10:00:00Z", "2026-03-01T10:00:00Z"), ("2026-10-24T10:00:00Z", "2026-10-25T10:00:00Z"),
                     ("2026-05-31T22:30:00Z", "2025-11-30T23:45:00Z")]
        for (from, to) in pairs {
            let shift = DateShift(from: date(from), to: date(to), calendar: paris)
            #expect(shift.applied(to: date(from), calendar: paris) == date(to), "\(from) to \(to) gave \(shift)")
        }
    }

    @Test func settingReplacesTheDateAndShiftingNeedsOne() {
        let shot = date("2026-10-29T13:03:12Z")
        #expect(DateAdjustment.set(shot.addingTimeInterval(0.6)).applied(to: nil) == shot, "to the second")
        #expect(DateAdjustment.set(shot).applied(to: .distantPast) == shot)
        #expect(DateAdjustment.shift(DateShift(hours: 1)).applied(to: nil) == nil)
        #expect(DateAdjustment.shift(DateShift(minutes: 5)).applied(to: shot) == shot.addingTimeInterval(300))
    }
}

@MainActor
struct MetadataEditingTests {
    /// Waits for an undo or redo, which writes in a task of its own.
    private func wait(until condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func correctingDatesIsOneUndoableStep() async throws {
        let source = SampleLibrarySource(count: 3)
        let first = source.assets[0], second = source.assets[1]
        let firstDate = try #require(first.creationDate), secondDate = try #require(second.creationDate)
        let manager = UndoManager()
        manager.groupsByEvent = false

        manager.beginUndoGrouping()
        let count = try await MetadataEditing.setCaptureDates([(first, firstDate.addingTimeInterval(3600)), (second, secondDate.addingTimeInterval(3600))],
                                                              in: source, undoManager: manager)
        manager.endUndoGrouping()
        #expect(count == 2)
        #expect(source.captureDate(for: first) == firstDate.addingTimeInterval(3600))
        #expect(source.captureDate(for: second) == secondDate.addingTimeInterval(3600))
        #expect(manager.canUndo && manager.undoActionName == "Adjust Date & Time")

        manager.undo()
        await wait { source.captureDate(for: first) == firstDate && source.captureDate(for: second) == secondDate }
        #expect(source.captureDate(for: first) == firstDate && source.captureDate(for: second) == secondDate)
        #expect(manager.canRedo && manager.redoActionName == "Adjust Date & Time")

        manager.redo()
        await wait { source.captureDate(for: second) == secondDate.addingTimeInterval(3600) }
        #expect(source.captureDate(for: first) == firstDate.addingTimeInterval(3600))
        #expect(source.captureDate(for: second) == secondDate.addingTimeInterval(3600))
    }

    @Test func decisionsAreWrittenToManyPhotosAsOneUndoableStepAndSkipWhatIsAlreadySo() async throws {
        let source = SampleLibrarySource(count: 4)
        // Ratings are 0, 1, 2 to start with.
        let assets = Array(source.assets.prefix(3)).sorted { $0.rating < $1.rating }
        let manager = UndoManager()
        manager.groupsByEvent = false

        manager.beginUndoGrouping()
        let written = try await MetadataEditing.apply(assets.map { ($0, .rating(2)) }, in: source, undoManager: manager)
        manager.endUndoGrouping()
        #expect(written == 2, "the photo already rated 2 is left alone")
        #expect(assets.allSatisfy { source.asset(id: $0.id)?.rating == 2 })
        #expect(manager.undoActionName == "Rating")

        manager.undo()
        await wait { assets.map { source.asset(id: $0.id)?.rating } == [0, 1, 2] }
        #expect(assets.map { source.asset(id: $0.id)?.rating } == [0, 1, 2])

        // Nothing to change: nothing to undo either.
        let idle = UndoManager()
        #expect(try await MetadataEditing.apply([(assets[2], .rating(2))], in: source, undoManager: idle) == 0)
        #expect(!idle.canUndo)
    }

    @Test func aSourceThatCannotStoreDatesReportsItAndLeavesNothingToUndo() async {
        let source = SampleLibrarySource(count: 1)
        source.capabilities = [.rating]
        let manager = UndoManager()
        await #expect(throws: LibrarySourceError.self) {
            try await MetadataEditing.setCaptureDates([(source.assets[0], .now)], in: source, undoManager: manager)
        }
        #expect(!manager.canUndo)
    }
}

@MainActor
struct CaptureDateEditModelTests {
    @Test func settingADateGivesItToEveryPhoto() async throws {
        let source = SampleLibrarySource(count: 3)
        let assets = Array(source.assets.prefix(2))
        let model = CaptureDateEditModel(assets: assets, source: source)
        let earliest = try #require(assets.compactMap(\.creationDate).min())
        #expect(model.mode == .set && model.date == earliest, "opens on the earliest photo's date")
        #expect(model.assets.first.flatMap { source.captureDate(for: $0) } == earliest)
        #expect(model.canApply, "the other photo has another date: giving it this one is a change")
        let wanted = try #require(ISO8601DateFormatter().date(from: "2026-10-29T13:03:12Z"))
        model.date = wanted
        #expect(model.exampleDate == earliest && model.adjustedExampleDate == wanted)
        #expect(model.canApply)

        #expect(await model.apply(undoManager: nil))
        #expect(source.captureDate(for: assets[0]) == wanted && source.captureDate(for: assets[1]) == wanted)
        #expect(try source.captureDate(for: #require(source.assets.first { !assets.map(\.id).contains($0.id) })) != wanted, "the unselected photo keeps its date")
    }

    @Test func shiftingMovesEachPhotoFromItsOwnDate() async throws {
        let source = SampleLibrarySource(count: 3)
        let assets = Array(source.assets.prefix(2))
        let before = assets.map { source.captureDate(for: $0)! }
        let model = CaptureDateEditModel(assets: assets, source: source)
        model.mode = .shift
        #expect(model.shift.isZero && !model.canApply, "the shift starts at nothing, and a shift of nothing changes nothing")

        model.shift = DateShift(hours: 2, minutes: 30, direction: .earlier)
        #expect(try model.adjustedExampleDate == #require(before.min()?.addingTimeInterval(-9000)) && model.undatedCount == 0)
        let manager = UndoManager()
        #expect(await model.apply(undoManager: manager))
        #expect(source.captureDate(for: assets[0]) == before[0].addingTimeInterval(-9000))
        #expect(source.captureDate(for: assets[1]) == before[1].addingTimeInterval(-9000))
        #expect(manager.canUndo)
    }

    @Test func theResultCanBeCheckedOnEachSelectedPhoto() throws {
        let source = SampleLibrarySource(count: 4)
        let assets = Array(source.assets.prefix(3))
        let dates = try assets.map { try #require(source.captureDate(for: $0)) }.sorted()
        let model = CaptureDateEditModel(assets: assets, source: source)
        model.mode = .shift
        model.shift = DateShift(hours: 1)

        // Opens on the earliest photo, then steps towards the latest and stops there.
        #expect(model.exampleIndex == 0 && !model.canShowPreviousExample && model.canShowNextExample)
        #expect(model.exampleDate == dates[0] && model.adjustedExampleDate == dates[0].addingTimeInterval(3600))
        model.showNextExample()
        #expect(model.exampleAsset.flatMap { source.captureDate(for: $0) } == dates[1])
        #expect(model.exampleDate == dates[1] && model.adjustedExampleDate == dates[1].addingTimeInterval(3600))
        model.showNextExample()
        model.showNextExample()
        #expect(model.exampleIndex == 2 && !model.canShowNextExample && model.exampleDate == dates[2])
        model.showPreviousExample()
        #expect(model.exampleIndex == 1)

        // Setting a date gives the same result whatever the photo shown.
        model.mode = .set
        model.date = dates[0].addingTimeInterval(-60)
        #expect(model.adjustedExampleDate == dates[0].addingTimeInterval(-60) && model.exampleDate == dates[1])
    }

    @Test func givingTheRealDateOfOnePhotoShiftsThemAll() async throws {
        let source = SampleLibrarySource(count: 4)
        let assets = Array(source.assets.prefix(3))
        let model = CaptureDateEditModel(assets: assets, source: source)
        let before = try model.assets.map { try #require(source.captureDate(for: $0)) }

        // The second photo is known to have been taken 1 day, 2 hours and 5 minutes later than its file says.
        model.showNextExample()
        let real = try #require(Calendar.current.date(byAdding: DateComponents(day: 1, hour: 2, minute: 5), to: before[1]))
        model.shiftSoExampleBecomes(real)
        #expect(model.mode == .shift && model.shift == DateShift(days: 1, hours: 2, minutes: 5))
        #expect(model.adjustedExampleDate == real)

        #expect(await model.apply(undoManager: nil))
        for (asset, date) in zip(model.assets, before) {
            #expect(source.captureDate(for: asset) == DateShift(days: 1, hours: 2, minutes: 5).applied(to: date))
        }
    }

    @Test func theHiddenTwinOfAPairFollowsItsRAW() async throws {
        let source = SampleLibrarySource(count: 3, pairsFirstTwo: true)
        let raw = try #require(source.asset(id: "sample-0")), twin = try #require(source.asset(id: "sample-1"))
        let twinDate = try #require(source.captureDate(for: twin))
        // Only the RAW is selected: its JPEG twin is usually hidden from the grid.
        let model = CaptureDateEditModel(assets: [raw], source: source)
        #expect(model.assets.count == 1)
        model.mode = .shift
        model.shift = DateShift(days: 1)
        #expect(await model.apply(undoManager: nil))
        #expect(source.captureDate(for: twin) == DateShift(days: 1).applied(to: twinDate))

        // Both selected: each is written once.
        let both = CaptureDateEditModel(assets: [raw, twin], source: source)
        both.mode = .shift
        both.shift = DateShift(hours: 1)
        #expect(both.changes.count == 2)
    }
}

struct ExportCaptureDateTests {
    @Test func theExportWritesTheLibrarysDateOnlyWhenItDiffersFromTheFiles() {
        let shot = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ExportItem.captureDateToWrite(library: shot, file: shot) == nil)
        #expect(ExportItem.captureDateToWrite(library: shot, file: shot.addingTimeInterval(0.4)) == nil, "sub-seconds are no correction")
        #expect(ExportItem.captureDateToWrite(library: shot.addingTimeInterval(3600), file: shot) == shot.addingTimeInterval(3600))
        #expect(ExportItem.captureDateToWrite(library: shot, file: nil) == shot, "a date given to a file that had none")
        #expect(ExportItem.captureDateToWrite(library: nil, file: shot) == nil)
    }
}

@MainActor
struct CorrectedDateExportTests {
    /// The whole path on a folder: a JPEG shot at a known time, corrected in the library, exported.
    @Test func anExportOfAFolderPhotoCarriesTheCorrectedDateAndTheOriginalKeepsItsOwn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CorrectedDateExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("clock.jpg")
        let context = try #require(CGContext(data: nil, width: 24, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 12))
        let exif: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:29 14:03:12", kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
        ]]
        let destination = try #require(CGImageDestinationCreateWithURL(image as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), exif as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let shot = try #require(ISO8601DateFormatter().date(from: "2026-10-29T13:03:12Z"))

        let source = try FolderLibrarySource(folder: CatalogFolder(bookmark: Data(), displayName: "Trip"), url: root, store: CatalogStore.inMemory(),
                                             previewCache: PreviewCache(directory: root.appendingPathComponent(".previews")))
        await source.load()
        for _ in 0 ..< 400 where source.assets.first?.creationDate != shot || source.isScanning {
            try await Task.sleep(for: .milliseconds(5))
        }
        let asset = try #require(source.assets.first)

        // Untouched, the export has nothing to correct.
        #expect(try await ExportItem.make(for: asset, in: source).load().captureDate == nil)

        // The clock was an hour and a half late.
        let model = CaptureDateEditModel(assets: [asset], source: source)
        model.mode = .shift
        model.shift = DateShift(hours: 1, minutes: 30)
        #expect(await model.apply(undoManager: nil))
        let corrected = shot.addingTimeInterval(5400)

        let input = try await ExportItem.make(for: asset, in: source).load()
        #expect(input.captureDate == corrected)
        let exported = try await ExportRenderer.export(input, settings: ExportSettings(format: .jpeg))
        let exportedSource = try #require(CGImageSourceCreateWithData(exported as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(exportedSource, 0, nil) as? [CFString: Any])
        #expect(ImageMetadataReader.metadata(from: properties).captureDate == corrected)
        let written = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(written[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:29 15:33:12", "the photo's own +01:00 is kept")
        #expect(try ImageMetadataReader.read(image).captureDate == shot, "the original still says what the camera wrote")
    }
}
