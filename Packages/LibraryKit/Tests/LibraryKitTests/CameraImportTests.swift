import Foundation
@testable import LibraryKit
import Testing

/// Importing photos from a device into a folder, with a fake device and temporary folders.
@MainActor
struct CameraImportTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @MainActor
    private struct Fixture {
        let base: URL
        let folder: URL
        let source: CameraLibrarySource
        let connection: FakeCameraConnection

        /// Every file under the folder, by relative path.
        func files() -> [String] {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            let prefix = folder.resolvingSymlinksInPath().path + "/"
            return (enumerator?.compactMap { $0 as? URL } ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") }
                .sorted()
        }
    }

    /// A device listed with these files, each `size` bytes of its own content.
    private func makeFixture(_ files: [CameraFile]) async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CameraImportTests-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let connection = FakeCameraConnection()
        let source = CameraLibrarySource(connection: connection)
        await source.load()
        for file in files {
            connection.contents[file.id] = Data(repeating: UInt8(truncatingIfNeeded: file.id.hashValue), count: Int(file.byteSize))
        }
        connection.send(.added(files))
        connection.send(.listed)
        return Fixture(base: base, folder: folder, source: source, connection: connection)
    }

    @Test func photosAreFiledByDayOrNotAtAll() {
        let day = Self.calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 10))
        #expect(ImportLayout.byDay.subfolder(for: day, calendar: Self.calendar) == "2026/2026-03-07")
        #expect(ImportLayout.flat.subfolder(for: day, calendar: Self.calendar) == nil)
        // A photo without a date goes to the folder itself.
        #expect(ImportLayout.byDay.subfolder(for: nil, calendar: Self.calendar) == nil)
    }

    @Test func theFoldersAnImportWillFillAreToldBeforehand() {
        func day(_ month: Int, _ day: Int) -> Date? {
            Self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 10))
        }
        let dates = [day(3, 7), day(3, 7), day(11, 19), nil, day(3, 8), day(3, 7)]
        let byDay = ImportLayout.byDay.folders(for: dates, calendar: Self.calendar)
        // The most recent day first, the photos without a date last, in the folder itself.
        #expect(byDay.map(\.subfolder) == ["2026/2026-11-19", "2026/2026-03-08", "2026/2026-03-07", nil])
        #expect(byDay.map(\.count) == [1, 1, 3, 1])
        #expect(ImportLayout.flat.folders(for: dates, calendar: Self.calendar) == [ImportFolderPreview(subfolder: nil, count: 6)])
        let none: [Date?] = []
        #expect(ImportLayout.byDay.folders(for: none, calendar: Self.calendar).isEmpty)
    }

    @Test func importingCopiesThePhotosIntoAFolderPerDay() async throws {
        let fixture = try await makeFixture([
            CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 10)),
            CameraFile(id: "DCIM/100/IMG_0002.CR2", byteSize: 900, creationDate: date(2021, 11, 11), isRAW: true),
            CameraFile(id: "DCIM/100/IMG_0002.JPG", byteSize: 200, creationDate: date(2021, 11, 11)),
            CameraFile(id: "DCIM/100/IMG_0003.JPG", byteSize: 100, creationDate: nil),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        // Three photos: the RAW and its JPEG are one.
        #expect(fixture.source.assets.count == 3)

        let job = try #require(fixture.source.startImport(of: Array(fixture.source.assets), into: .folder(fixture.folder, layout: .byDay), named: "Photos"))
        #expect(job.total == 3)
        // One import at a time from a device.
        #expect(fixture.source.startImport(of: Array(fixture.source.assets), into: .folder(fixture.folder, layout: .byDay), named: "Photos") == nil)
        await job.wait()

        #expect(job.isFinished)
        #expect(job.done == 3)
        #expect(job.importedCount == 3)
        #expect(job.failures.isEmpty)
        #expect(fixture.files() == ["2021/2021-11-10/IMG_0001.JPG", "2021/2021-11-11/IMG_0002.CR2", "2021/2021-11-11/IMG_0002.JPG", "IMG_0003.JPG"])
        #expect(job.imported.count == 4)
        let raw = try Data(contentsOf: fixture.folder.appendingPathComponent("2021/2021-11-11/IMG_0002.CR2"))
        #expect(raw == fixture.connection.contents["DCIM/100/IMG_0002.CR2"])
        #expect(fixture.source.currentImport === job)
        // Nothing of the staging copies is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0 == "Import-\(job.id.uuidString)" }
        #expect(leftovers.isEmpty)
    }

    @Test func aPhotoAlreadyThereIsLeftAloneAndASameNameOfAnotherSizeIsKept() async throws {
        let fixture = try await makeFixture([
            CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 10)),
            CameraFile(id: "DCIM/100/IMG_0002.JPG", byteSize: 200, creationDate: date(2021, 11, 10)),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        // Imported once before: the same name and size. And another photo that only has the name.
        try fixture.connection.contents["DCIM/100/IMG_0001.JPG"]?.write(to: fixture.folder.appendingPathComponent("IMG_0001.JPG"))
        try Data(repeating: 7, count: 50).write(to: fixture.folder.appendingPathComponent("IMG_0002.JPG"))

        let job = try #require(fixture.source.startImport(of: Array(fixture.source.assets), into: .folder(fixture.folder, layout: .flat), named: "Photos"))
        await job.wait()
        #expect(job.done == 2)
        #expect(job.alreadyThere == 1)
        #expect(job.importedCount == 1)
        #expect(fixture.files() == ["IMG_0001.JPG", "IMG_0002 2.JPG", "IMG_0002.JPG"])
        #expect(fixture.connection.requests == ["download DCIM/100/IMG_0002.JPG"])
        // The file that was there is untouched.
        #expect(try Data(contentsOf: fixture.folder.appendingPathComponent("IMG_0002.JPG")).count == 50)
    }

    @Test func aFileTheDeviceCutsShortOrDoesNotGiveIsNotKept() async throws {
        let fixture = try await makeFixture([
            CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 10)),
            CameraFile(id: "DCIM/100/IMG_0002.JPG", byteSize: 200, creationDate: date(2021, 11, 10)),
            CameraFile(id: "DCIM/100/IMG_0003.JPG", byteSize: 100, creationDate: date(2021, 11, 10)),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        // The card was pulled out while this one was copied; that one can't be read at all.
        fixture.connection.contents["DCIM/100/IMG_0001.JPG"] = Data(repeating: 1, count: 120)
        fixture.connection.contents["DCIM/100/IMG_0002.JPG"] = nil

        let job = try #require(fixture.source.startImport(of: Array(fixture.source.assets), into: .folder(fixture.folder, layout: .flat), named: "Photos"))
        await job.wait()
        #expect(job.done == 3)
        #expect(job.importedCount == 1)
        #expect(job.failures.count == 2)
        #expect(fixture.files() == ["IMG_0003.JPG"])
    }

    @Test func aCancelledImportKeepsWhatItCopied() async throws {
        let files = (1 ... 30).map { CameraFile(id: "DCIM/100/IMG_00\($0).JPG", byteSize: 64, creationDate: date(2021, 11, 10).addingTimeInterval(Double($0))) }
        let fixture = try await makeFixture(files)
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let job = try #require(fixture.source.startImport(of: Array(fixture.source.assets), into: .folder(fixture.folder, layout: .flat), named: "Photos"))
        await waitUntil { job.done >= 3 }
        job.cancel()
        await job.wait()
        #expect(job.isCancelled)
        #expect(job.isFinished)
        #expect(job.done < 30)
        #expect(fixture.files().count == job.imported.count)
        // Another import can follow, and brings the rest.
        let rest = try #require(fixture.source.startImport(of: Array(fixture.source.assets), into: .folder(fixture.folder, layout: .flat), named: "Photos"))
        await rest.wait()
        #expect(fixture.files().count == 30)
        #expect(rest.alreadyThere == job.imported.count)
    }

    @Test func importingIntoALibraryHandsOverTheCheckedFilesOfEachPhoto() async throws {
        let fixture = try await makeFixture([
            CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 10)),
            CameraFile(id: "DCIM/100/IMG_0002.CR2", byteSize: 900, creationDate: date(2021, 11, 11), isRAW: true),
            CameraFile(id: "DCIM/100/IMG_0002.JPG", byteSize: 200, creationDate: date(2021, 11, 11)),
            CameraFile(id: "DCIM/100/IMG_0003.JPG", byteSize: 100, creationDate: date(2021, 11, 12)),
            CameraFile(id: "DCIM/100/IMG_0004.JPG", byteSize: 100, creationDate: date(2021, 11, 13)),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        // One file is cut short by the device, and the library refuses another photo.
        fixture.connection.contents["DCIM/100/IMG_0003.JPG"] = Data(repeating: 1, count: 40)

        // What the library was handed, photo by photo.
        actor Library {
            var photos: [[String]] = []
            var sizes: [Int] = []
            func take(_ photo: ImportedPhoto) throws -> String {
                if photo.files.contains(where: { $0.name == "IMG_0004.JPG" }) {
                    throw LibrarySourceError.editingFailed("refused")
                }
                photos.append(photo.files.map { "\($0.name)\($0.isRAW ? " (RAW)" : "")" })
                sizes.append(contentsOf: photo.files.map { (try? Data(contentsOf: $0.url).count) ?? -1 })
                return "photo-\(photos.count)"
            }
        }
        let library = Library()
        let job = try #require(fixture.source.startImport(of: Array(fixture.source.assets), into: .library { try await library.take($0) }, named: "Photos"))
        await job.wait()

        #expect(job.done == 4)
        #expect(job.createdPhotoIDs == ["photo-1", "photo-2"])
        #expect(job.importedCount == 2)
        #expect(job.failures.count == 2)
        #expect(job.imported.isEmpty)
        // Newest first; the RAW and its JPEG as one photo; the files were there, whole, when handed over.
        #expect(await library.photos == [["IMG_0002.CR2 (RAW)", "IMG_0002.JPG"], ["IMG_0001.JPG"]])
        #expect(await library.sizes == [900, 200, 300])
        // Nothing of the temporary copies is left.
        #expect(fixture.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("Import-\(job.id.uuidString)").path))
    }

    // MARK: - New photos only

    @Test func photosImportedBeforeAreMarkedWhenTheCardIsReadAgain() async throws {
        let files = [
            CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 10)),
            CameraFile(id: "DCIM/100/IMG_0002.CR2", byteSize: 900, creationDate: date(2021, 11, 11), isRAW: true),
            CameraFile(id: "DCIM/100/IMG_0002.JPG", byteSize: 200, creationDate: date(2021, 11, 11)),
            CameraFile(id: "DCIM/100/IMG_0003.JPG", byteSize: 100, creationDate: date(2021, 11, 12)),
        ]
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CameraImportTests-\(UUID().uuidString)")
        let folder = base.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let history = ImportHistory(fileURL: base.appendingPathComponent("History.json"))
        let browser = FakeCameraBrowser()
        let plugged = CameraDevices(browser: browser, history: history)
        plugged.start()

        // The card, plugged in and listed.
        func plug(id: String) async throws -> (CameraLibrarySource, FakeCameraConnection) {
            let connection = FakeCameraConnection(id: id)
            for file in files {
                connection.contents[file.id] = Data(repeating: 1, count: Int(file.byteSize))
            }
            browser.onConnect?(connection)
            let source = try #require(plugged.source(id: id))
            await source.load()
            connection.send(.added(files))
            connection.send(.listed)
            return (source, connection)
        }

        let (card, _) = try await plug(id: "first")
        #expect(card.newPhotoCount == 3)
        #expect(card.assets.allSatisfy { !$0.isImported })

        // Two photos are imported, one of them the RAW with its JPEG.
        let picked = card.assets.filter { $0.id != "DCIM/100/IMG_0003.JPG" }
        let job = try #require(card.startImport(of: picked, into: .folder(folder, layout: .flat), named: "Photos"))
        await job.wait()
        #expect(job.importedFiles.count == 3)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        history.record(ImportRecord(deviceName: "EOS_DIGITAL", destination: .folder(id: UUID()), relativePaths: ["IMG_0001.JPG"]), files: job.importedFiles, undoManager: undoManager)
        undoManager.endUndoGrouping()

        // The card on screen follows at once.
        #expect(card.newPhotoCount == 1)
        #expect(card.assets.filter(\.isImported).map(\.id).sorted() == ["DCIM/100/IMG_0001.JPG", "DCIM/100/IMG_0002.CR2"])
        #expect(history.lastImport?.relativePaths == ["IMG_0001.JPG"])

        // Pulled out, the app relaunched, the card plugged in again: the history was kept.
        await history.settled()
        let reopened = ImportHistory(fileURL: base.appendingPathComponent("History.json"))
        await reopened.load()
        #expect(reopened.contains(ImportedFileSignature(files[0])))
        #expect(!reopened.contains(ImportedFileSignature(files[3])))
        #expect(reopened.lastImport == history.lastImport)
        browser.onDisconnect?("first")
        let (again, _) = try await plug(id: "second")
        #expect(again.newPhotoCount == 1)
        #expect(again.assets.first { !$0.isImported }?.id == "DCIM/100/IMG_0003.JPG")

        // Undoing the import makes its photos new again; redoing, imported again.
        undoManager.undo()
        #expect(again.newPhotoCount == 3)
        #expect(history.lastImport == nil)
        undoManager.redo()
        #expect(again.newPhotoCount == 1)
        #expect(history.lastImport != nil)
    }

    @Test func theLastImportShowsItsPhotosAloneInTheFolderTheyWentTo() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CameraImportTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2021/2021-11-10"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let image = CameraTestImages.jpeg(width: 40, height: 30, embeddingThumbnail: false)
        for name in ["old-1.jpg", "old-2.jpg"] {
            try image.write(to: root.appendingPathComponent(name))
        }
        let catalog = try LibraryCatalog(store: CatalogStore.inMemory(), previewCache: PreviewCache(directory: base.appendingPathComponent("Previews")))
        let folder = try await catalog.addFolder(root)
        await folder.load()
        await waitUntil { folder.assets.count == 2 }

        // An import brings two photos into a folder of the day.
        let imported = ["2021/2021-11-10/IMG_0001.jpg", "2021/2021-11-10/IMG_0002.jpg"]
        for path in imported {
            try image.write(to: root.appendingPathComponent(path))
        }
        folder.registerImport(of: imported.map { root.appendingPathComponent($0) }, undoManager: nil)
        let record = ImportRecord(deviceName: "EOS_DIGITAL", destination: .folder(id: folder.id), relativePaths: imported)
        guard case let .folder(view, scannedBy, _) = catalog.library(forLastImport: record) else {
            Issue.record("The last import should show through a view of its folder")
            return
        }
        #expect(scannedBy === folder)
        #expect(view !== folder)
        await view.load()
        // Before the folder has listed the new files, nothing shows: never the whole folder.
        #expect(view.assets.isEmpty)
        await waitUntil { folder.assets.count == 4 }
        await catalog.refreshLastImport(record)
        await waitUntil { view.assets.count == 2 }
        #expect(view.assets.count == 2)
        // The folder's own entry still shows everything, and the same view serves the same import.
        #expect(folder.assets.count == 4)
        if case let .folder(again, _, _) = catalog.library(forLastImport: record) {
            #expect(again === view)
        }
        // A folder removed from the sidebar takes its last import with it.
        #expect(catalog.library(forLastImport: ImportRecord(deviceName: "X", destination: .folder(id: UUID()), relativePaths: [])) == nil)
    }

    @Test func aFileIsToldByItsNameItsSizeAndItsDate() {
        let file = CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 10))
        let signature = ImportedFileSignature(file)
        // The same name on another card, or after the counter went round: another photo.
        #expect(signature != ImportedFileSignature(CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 301, creationDate: date(2021, 11, 10))))
        #expect(signature != ImportedFileSignature(CameraFile(id: "DCIM/100/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 11))))
        // The folder it is in on the card doesn't count: cameras move on to new ones.
        #expect(signature == ImportedFileSignature(CameraFile(id: "DCIM/101/IMG_0001.JPG", byteSize: 300, creationDate: date(2021, 11, 10))))
    }

    @Test func ejectingAsksTheDevice() async throws {
        let fixture = try await makeFixture([])
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try await fixture.source.eject()
        #expect(fixture.connection.isEjected)
    }

    @Test func undoingAnImportMovesItsFilesToTheTrashAndRedoingPutsThemBack() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CameraImportTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Photos")
        let trash = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2021/2021-11-10"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = try FolderLibrarySource(folder: CatalogFolder(bookmark: Data(), displayName: "Photos"), url: root, store: CatalogStore.inMemory(),
                                             previewCache: PreviewCache(directory: base.appendingPathComponent("Previews")), trash: .folder(trash))
        await folder.load()
        let imported = root.appendingPathComponent("2021/2021-11-10/IMG_0001.JPG")
        try Data(repeating: 3, count: 40).write(to: imported)

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        folder.registerImport(of: [imported], undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(undoManager.undoActionName == "Import Photo")

        undoManager.undo()
        await waitUntil { !FileManager.default.fileExists(atPath: imported.path) }
        #expect(!FileManager.default.fileExists(atPath: imported.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.contains("IMG_0001.JPG") == true)

        undoManager.redo()
        await waitUntil { FileManager.default.fileExists(atPath: imported.path) }
        #expect(FileManager.default.fileExists(atPath: imported.path))
    }
}
