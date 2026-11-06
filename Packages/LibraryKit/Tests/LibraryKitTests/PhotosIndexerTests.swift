import Foundation
@testable import LibraryKit
import Testing

struct PhotosIndexerTests {
    /// Collects the progress reports of a pass.
    private actor Reports {
        private(set) var all: [IndexingProgress] = []
        func add(_ progress: IndexingProgress) {
            all.append(progress)
        }
    }

    private func makeStore() throws -> PhotosIndexStore {
        try PhotosIndexStore(catalog: CatalogStore.inMemory())
    }

    private func library(count: Int, rawIDs: Set<String> = []) -> FakePhotosLibrary {
        FakePhotosLibrary((0 ..< count).map { FakePhotosLibrary.reading("p\($0)", "IMG_\($0).JPG", at: Double($0)) }, rawIDs: rawIDs)
    }

    @Test func buildsTheIndexInBatches() async throws {
        let store = try makeStore()
        let library = library(count: 5, rawIDs: ["p1"])
        let reports = Reports()

        let outcome = try await PhotosIndexer(store: store, library: library, batchSize: 2).update(rawIDs: ["p1"]) { await reports.add($0) }

        #expect(outcome == .init(mode: .full, read: 5, deleted: 0, isComplete: true))
        #expect(await library.readRequests == [["p0", "p1"], ["p2", "p3"], ["p4"]])
        #expect(await reports.all.map(\.done) == [0, 2, 4, 5])
        #expect(await reports.all.allSatisfy { $0.total == 5 })
        #expect(try await store.entry(id: "p1")?.isRAW == true)
        #expect(try await store.entry(id: "p3")?.fileName == "IMG_3.JPG")
        #expect(try await store.changeToken() == library.currentChangeToken())
    }

    @Test func resumesAnInterruptedBuild() async throws {
        let store = try makeStore()
        let library = library(count: 5)
        let indexer = PhotosIndexer(store: store, library: library, batchSize: 2)

        // Quitting the app cancels the pass: here, right after the first batch.
        let interrupted = try await Task {
            try await indexer.update(rawIDs: []) { progress in
                if progress.done == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.value
        #expect(interrupted.isComplete == false)
        #expect(try await store.count() == 2)
        #expect(try await store.changeToken() == nil)

        let reports = Reports()
        let resumed = try await indexer.update(rawIDs: []) { await reports.add($0) }
        #expect(resumed == .init(mode: .full, read: 3, deleted: 0, isComplete: true))
        #expect(await library.readRequests == [["p0", "p1"], ["p2", "p3"], ["p4"]])
        #expect(await reports.all.first == IndexingProgress(done: 2, total: 5))
        #expect(try await store.count() == 5)
        #expect(try await store.changeToken() != nil)
    }

    @Test func readsOnlyWhatChangedSinceTheLastPass() async throws {
        let store = try makeStore()
        let library = library(count: 4)
        let indexer = PhotosIndexer(store: store, library: library)
        try await indexer.update(rawIDs: [])

        // Changes made while the app was closed, or by Photos itself.
        await library.add(FakePhotosLibrary.reading("new", "DSCF0001.RAF", at: 50), isRAW: true)
        await library.rename("p2", to: "Renamed.JPG")
        await library.remove("p3")

        let outcome = try await indexer.update(rawIDs: library.rawAssetIDs())
        #expect(outcome == .init(mode: .incremental, read: 2, deleted: 1, isComplete: true))
        #expect(await library.readRequests.last == ["new", "p2"])
        #expect(try await store.assetIDs() == ["p0", "p1", "p2", "new"])
        #expect(try await store.entry(id: "p2")?.fileName == "Renamed.JPG")
        #expect(try await store.entry(id: "new")?.isRAW == true)

        // Up to date: nothing is read again.
        let idle = try await indexer.update(rawIDs: library.rawAssetIDs())
        #expect(idle == .init(mode: .incremental, read: 0, deleted: 0, isComplete: true))
    }

    @Test func rebuildsWhenTheHistoryNoLongerReachesBack() async throws {
        let store = try makeStore()
        let library = library(count: 3)
        let indexer = PhotosIndexer(store: store, library: library)
        try await indexer.update(rawIDs: [])

        // Too long since the last launch: what changed meanwhile is unknown.
        await library.rename("p1", to: "Edited.JPG")
        await library.remove("p2")
        await library.expireHistory()

        let outcome = try await indexer.update(rawIDs: [])
        #expect(outcome == .init(mode: .full, read: 2, deleted: 0, isComplete: true))
        #expect(try await store.assetIDs() == ["p0", "p1"])
        #expect(try await store.entry(id: "p1")?.fileName == "Edited.JPG")
        #expect(try await store.changeToken() == library.currentChangeToken())
    }

    @Test func dropsAssetsThatLeftTheLibrary() async throws {
        let store = try makeStore()
        let library = library(count: 2)
        try await store.save([PhotosAssetEntry(id: "gone", fileName: "gone.jpg", captureDate: nil, isRAW: false)])

        let outcome = try await PhotosIndexer(store: store, library: library).update(rawIDs: [])
        #expect(outcome == .init(mode: .full, read: 2, deleted: 1, isComplete: true))
        #expect(try await store.assetIDs() == ["p0", "p1"])
    }

    @Test func followsTheRAWSetWithoutReadingAssetsAgain() async throws {
        let store = try makeStore()
        let library = library(count: 3)
        let indexer = PhotosIndexer(store: store, library: library)
        try await indexer.update(rawIDs: ["p0"])

        let outcome = try await indexer.update(rawIDs: ["p2"])
        #expect(outcome.read == 0)
        #expect(try await store.entry(id: "p0")?.isRAW == false)
        #expect(try await store.entry(id: "p2")?.isRAW == true)
    }

    @Test func indexesKeywordsAndFollowsTheirChanges() async throws {
        let store = try makeStore()
        let library = FakePhotosLibrary([
            FakePhotosLibrary.reading("a", "DSCF0001.RAF", keywords: ["Lapland", "Winter"]),
            FakePhotosLibrary.reading("b", "DSCF0002.RAF"),
        ])
        let indexer = PhotosIndexer(store: store, library: library)
        try await indexer.update(rawIDs: [])
        #expect(try await store.search("lapland") == ["a"])

        // Keywords edited in Photos, or in Qaama: the asset comes back as changed.
        await library.setKeywords(["Aurora"], of: "b")
        await library.setKeywords([], of: "a")
        try await indexer.update(rawIDs: [])
        #expect(try await store.search("lapland") == [])
        #expect(try await store.search("aurora") == ["b"])
    }

    @Test func reportsNoProgressForASmallChange() async throws {
        let store = try makeStore()
        let library = library(count: 3)
        let indexer = PhotosIndexer(store: store, library: library, batchSize: 2)
        try await indexer.update(rawIDs: [])
        await library.rename("p0", to: "Renamed.JPG")

        let reports = Reports()
        try await indexer.update(rawIDs: []) { await reports.add($0) }
        #expect(await reports.all.isEmpty)
    }
}
