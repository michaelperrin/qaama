import Foundation
@testable import LibraryKit
import Testing

@MainActor
struct PhotosIndexTests {
    private func makeIndex(_ library: FakePhotosLibrary, catalog: CatalogStore? = nil) throws -> PhotosIndex {
        try PhotosIndex(store: PhotosIndexStore(catalog: catalog ?? CatalogStore.inMemory()), library: library, settleDelay: .milliseconds(10))
    }

    /// Waits for a change the library announced to reach the index.
    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func findsTheRAWSetAndThePairsOnTheFirstPass() async throws {
        let library = FakePhotosLibrary([
            FakePhotosLibrary.reading("raw", "IMG_0204.CR2", at: 100),
            FakePhotosLibrary.reading("twin", "IMG_0204.JPG", at: 100),
            FakePhotosLibrary.reading("jpeg", "IMG_0300.JPG", at: 200),
        ], rawIDs: ["raw"])
        let index = try makeIndex(library)

        await index.start()
        await index.waitUntilIdle()
        #expect(index.snapshot.rawIDs == ["raw"])
        #expect(index.snapshot.twinIDs == ["twin"])
        #expect(index.snapshot.pairedIDs == ["raw": "twin", "twin": "raw"])
        #expect(index.progress == nil)
    }

    @Test func startsFromWhatTheLastSessionKnew() async throws {
        let catalog = try CatalogStore.inMemory()
        let library = FakePhotosLibrary([
            FakePhotosLibrary.reading("raw", "IMG_0204.CR2", at: 100),
            FakePhotosLibrary.reading("twin", "IMG_0204.JPG", at: 100),
        ], rawIDs: ["raw"])
        let firstSession = try makeIndex(library, catalog: catalog)
        await firstSession.start()
        await firstSession.waitUntilIdle()

        // Photos reclassified the pair while the app was closed.
        await library.setRAW([])
        let secondSession = try makeIndex(library, catalog: catalog)
        await secondSession.start()
        // Before any pass: the catalog's answer, without asking the library.
        #expect(secondSession.snapshot.rawIDs == ["raw"])
        #expect(secondSession.snapshot.twinIDs == ["twin"])

        await secondSession.waitUntilIdle()
        #expect(secondSession.snapshot == PhotosIndexSnapshot())
    }

    @Test func followsTheLibrarysChanges() async throws {
        let library = FakePhotosLibrary([FakePhotosLibrary.reading("jpeg", "DSCF0001.JPG", at: 100)])
        let index = try makeIndex(library)
        await index.start()
        await index.waitUntilIdle()
        #expect(index.snapshot == PhotosIndexSnapshot())

        // The RAW of an existing JPEG is imported in Photos.
        await library.add(FakePhotosLibrary.reading("raw", "DSCF0001.RAF", at: 100), isRAW: true)
        // The RAW set is known as soon as the pass starts, the pair once the new asset is read.
        await waitFor { index.snapshot.twinIDs == ["jpeg"] }
        #expect(index.snapshot.rawIDs == ["raw"])
        #expect(index.snapshot.twinIDs == ["jpeg"])

        await library.remove("raw")
        await waitFor { index.snapshot == PhotosIndexSnapshot() }
        #expect(index.snapshot == PhotosIndexSnapshot())
    }

    @Test func tellsWhenWhatSearchReadsChanged() async throws {
        let library = FakePhotosLibrary([FakePhotosLibrary.reading("a", "DSCF0001.RAF")])
        let index = try makeIndex(library)
        await index.start()
        await index.waitUntilIdle()
        let built = index.contentVersion
        #expect(built > 0)
        #expect(try await index.search("dscf") == ["a"])

        await library.setKeywords(["Lapland"], of: "a")
        await waitFor { index.contentVersion > built }
        #expect(try await index.search("lapland") == ["a"])
    }

    @Test func startingTwiceRunsOnePass() async throws {
        let library = FakePhotosLibrary([FakePhotosLibrary.reading("a", "a.jpg")])
        let index = try makeIndex(library)
        await index.start()
        await index.start()
        await index.waitUntilIdle()
        #expect(await library.readRequests == [["a"]])
    }
}
