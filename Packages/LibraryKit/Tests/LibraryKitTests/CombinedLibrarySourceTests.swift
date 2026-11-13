import CoreGraphics
import Foundation
import ImageIO
import ImageIOKit
@testable import LibraryKit
import Testing
import UniformTypeIdentifiers

@MainActor
struct CombinedLibrarySourceTests {
    /// Two sample libraries shown as one. "a" shoots a photo a day from the 14th of November 2023
    /// backwards (22:13 UTC), "b" one every other day at the same hour: a-0 and b-0 share a date.
    private func makeLibrary(aCount: Int = 4, bCount: Int = 3) async -> (CombinedLibrarySource, SampleLibrarySource, SampleLibrarySource) {
        let a = SampleLibrarySource(displayName: "A", count: aCount, idPrefix: "a")
        let b = SampleLibrarySource(displayName: "B", count: bCount, daysApart: 2, idPrefix: "b")
        let library = CombinedLibrarySource(displayName: "Map", members: [a, b])
        await library.load()
        return (library, a, b)
    }

    /// Opens a group as a double click on the map does: here, by default, every photo of both members.
    private func open(_ ids: Set<LibraryAsset.ID>? = nil, in library: CombinedLibrarySource) async {
        var group: Set<LibraryAsset.ID> = []
        for member in library.members {
            group.formUnion(member.assets.map(\.id))
        }
        library.query.onlyAssetIDs = ids ?? group
        await library.waitUntilWoven()
    }

    @Test func listsNothingUntilAGroupIsPickedOnTheMap() async {
        let (library, a, _) = await makeLibrary()

        // Loaded, with a map to show, and no grid of everything.
        #expect(library.isLoaded && library.assets.isEmpty && library.timeline == nil)
        #expect(await library.locatedAssets().count == 4)
        #expect(a.assets.count == 4)

        await open(["a-2", "b-1", "a-0"], in: library)
        #expect(library.assets.map(\.id) == ["a-0", "a-2", "b-1"])
        #expect(a.assets.map(\.id) == ["a-0", "a-2"])

        // Back to the map: the group is gone, the members list everything again.
        library.query.onlyAssetIDs = nil
        await library.waitUntilWoven()
        #expect(library.assets.isEmpty && library.timeline == nil && a.assets.count == 4)
    }

    @Test func weavesTheMembersByDate() async {
        let (library, _, _) = await makeLibrary()
        await open(in: library)

        #expect(library.assets.map(\.id) == ["a-0", "b-0", "a-1", "a-2", "b-1", "a-3", "b-2"])
        #expect(library.timeline?.count == 7)
        #expect(library.index(of: "b-1") == 4 && library.index(of: "a-0") == 0 && library.index(of: "nowhere") == nil)
        #expect(library.neighbor(of: "a-2", offset: 1) == "b-1")
        #expect(library.asset(id: "b-2")?.id == "b-2" && library.asset(id: "nowhere") == nil)
    }

    @Test func oldestFirstWeavesTheOtherWay() async {
        let (library, _, _) = await makeLibrary()
        await open(in: library)

        library.query.ascending = true
        await library.waitUntilWoven()
        // On the days both shot, the first member's photo still comes first.
        #expect(library.assets.map(\.id) == ["b-2", "a-3", "a-2", "b-1", "a-1", "a-0", "b-0"])
    }

    @Test func aFilterGoesToEveryMemberAndTheListingFollows() async {
        let (library, a, b) = await makeLibrary()
        await open(in: library)

        // Favorites are every fifth photo: the first of each member here.
        library.query.favoritesOnly = true
        await library.waitUntilWoven()
        #expect(a.query.favoritesOnly && b.query.favoritesOnly)
        #expect(library.assets.map(\.id) == ["a-0", "b-0"])

        library.query = library.query.clearingFilters
        await library.waitUntilWoven()
        #expect(library.assets.count == 7)
    }

    @Test func aDecisionGoesToThePhotosMemberAndShowsInTheListing() async throws {
        let (library, _, b) = await makeLibrary()
        await open(in: library)

        try await library.setRating(5, for: #require(library.asset(id: "b-1")))
        await library.waitUntilWoven()
        #expect(b.asset(id: "b-1")?.rating == 5)
        #expect(library.assets[4].id == "b-1" && library.assets[4].rating == 5)

        try await library.setKeywords(["sea"], for: #require(library.asset(id: "a-3")))
        #expect(try await library.keywords(for: #require(library.asset(id: "a-3"))) == ["sea"])
        await #expect(throws: LibrarySourceError.self) {
            try await library.setRating(1, for: LibraryAsset(id: "nowhere", pixelWidth: 1, pixelHeight: 1, creationDate: nil, isFavorite: false))
        }
    }

    @Test func thumbnailsAndEditsComeFromTheMemberHoldingThePhoto() async throws {
        let (library, a, b) = await makeLibrary()
        let photo = try #require(library.asset(id: "b-2"))

        #expect(await library.thumbnail(for: photo, pixelSize: CGSize(width: 64, height: 64)) != nil)
        try await library.saveEdit(EditingOutput(recipeData: Data([1]), renderedJPEG: Data()), for: photo)
        #expect(try await b.editingInput(for: photo).recipeData == Data([1]))
        #expect(try await library.editingInput(for: photo).recipeData == Data([1]))
        #expect(try await a.editingInput(for: #require(a.asset(id: "a-0"))).recipeData == nil)
    }

    @Test func offersOnlyWhatEveryMemberCanDo() async {
        let (library, a, _) = await makeLibrary()
        #expect(library.capabilities == [.rating, .flag, .keywords, .captureDate])
        // Orders other than by date don't weave.
        #expect(library.queryCapabilities == [.rating, .flag, .edited, .favorite, .search])

        a.capabilities = [.rating, .keywords]
        #expect(library.capabilities == [.rating, .keywords])
        #expect(CombinedLibrarySource(displayName: "Empty").capabilities.isEmpty)
    }

    @Test func theMapShowsThePhotosOfEveryMember() async throws {
        let (library, a, _) = await makeLibrary()
        #expect(library.hasPlaces)
        // Every other photo is placed: a-0, a-2, b-0, b-2.
        #expect(await library.locatedAssets().map(\.id).sorted() == ["a-0", "a-2", "b-0", "b-2"])

        let model = PhotoMapModel()
        await model.load(from: library)
        model.show(region: GeoRegion(south: 41, west: -6, north: 52, east: 9), worldWidth: 20000, spacing: 90)
        await model.waitUntilSettled()
        // Paris holds a-0 and b-0, Lyon a-2 and b-2: groups mix the members, thumbnails come from either.
        #expect(model.clusters.map(\.count).sorted() == [2, 2])
        #expect(model.clusters.allSatisfy { model.cover(of: $0) != nil })

        // A group opened from the map narrows every member; the map still knows them all.
        let version = library.placesVersion
        await open(["a-0", "b-0"], in: library)
        #expect(library.assets.map(\.id) == ["a-0", "b-0"])
        #expect(await library.locatedAssets().count == 4)
        #expect(PhotoMapModel.Content(library).version == version)

        try? await a.setRating(5, for: try #require(a.asset(id: "a-2")))
        #expect(library.placesVersion != version)
    }

    @Test func membersCanComeAndGo() async {
        let (library, a, _) = await makeLibrary()
        let version = library.placesVersion
        let c = SampleLibrarySource(displayName: "C", count: 1, idPrefix: "c")

        library.setMembers([a, c])
        await library.waitUntilWoven()
        await open(in: library)
        #expect(library.assets.map(\.id) == ["a-0", "c-0", "a-1", "a-2", "a-3"])
        #expect(library.asset(id: "b-0") == nil)
        #expect(library.placesVersion != version)
        // The newcomer got the library's query.
        library.query.favoritesOnly = true
        await library.waitUntilWoven()
        #expect(c.query.favoritesOnly)
        #expect(library.assets.map(\.id) == ["a-0", "c-0"])
    }

    @Test func preparesBeforeLoadingItsMembers() async {
        let a = SampleLibrarySource(displayName: "A", count: 2, idPrefix: "a")
        let library = CombinedLibrarySource(displayName: "Map", members: [a])
        var prepared = 0
        library.prepare = { prepared += 1 }

        await library.load()
        await library.load()
        #expect(prepared == 1 && library.isLoaded && a.assets.count == 2)
    }

    @Test func aFolderAndItsSecondViewShareTheCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedLibrarySourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one.png", "two.png"] {
            let context = try #require(CGContext(data: nil, width: 12, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 6))
            let destination = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil))
            try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let store = try CatalogStore.inMemory()
        let folder = CatalogFolder(bookmark: Data(), displayName: "Trip")
        let cache = PreviewCache(directory: root.appendingPathComponent(".previews"))
        // The folder as its own library scans; its second view, a member of the map of everything, doesn't.
        let scanning = FolderLibrarySource(folder: folder, url: root, store: store, previewCache: cache)
        let view = FolderLibrarySource(folder: folder, url: root, store: store, previewCache: cache, scans: false)
        let samples = SampleLibrarySource(displayName: "Samples", count: 2, idPrefix: "s")
        let library = CombinedLibrarySource(displayName: "Map", members: [view, samples])
        library.prepare = { await scanning.load() }

        await library.load()
        for _ in 0 ..< 400 where view.assets.count != 2 || scanning.isScanning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await open(in: library)
        #expect(library.assets.count == 4)
        #expect(!view.isScanning)

        // The folder is filtered in its own entry: the group opened from the map isn't.
        scanning.query.minimumRating = 3
        let file = try #require(library.assets.first { library.fileURL(for: $0)?.lastPathComponent == "one.png" })
        try await library.setRating(4, for: file)
        for _ in 0 ..< 400 where scanning.assets.count != 1 || library.asset(id: file.id)?.rating != 4 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await library.waitUntilWoven()
        #expect(scanning.assets.map(\.id) == [file.id])
        #expect(library.assets.count == 4 && library.asset(id: file.id)?.rating == 4)
        #expect(!library.hasFileURLs)
    }
}
