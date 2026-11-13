import Foundation
@testable import LibraryKit
import Testing

struct PhotosAlbumSearchTests {
    private static func album(_ title: String) -> PhotosAlbumNode {
        .album(PhotosAlbum(id: "album-\(title)", title: title, kind: .user, estimatedCount: 0))
    }

    private static func folder(_ title: String, _ children: [PhotosAlbumNode]) -> PhotosAlbumNode {
        .folder(id: "folder-\(title)", title: title, children: children)
    }

    /// Albums at the top level and two folders deep.
    private static let tree: [PhotosAlbumNode] = [
        folder("Voyages", [
            folder("Asie", [album("Japon 2024"), album("Viêt Nam")]),
            album("Islande"),
            album("Retour du Japon"),
        ]),
        folder("Famille", [album("Noël 2024"), album("Bajapur")]),
        album("Japonaiseries"),
        album("À trier"),
    ]

    private func titles(_ query: String, excluding excludedID: String? = nil) -> [String] {
        PhotosAlbumSearch(tree: Self.tree, excluding: excludedID).matches(for: query).map(\.album.title)
    }

    @Test func nothingTypedListsEveryAlbumByTitle() {
        #expect(titles("") == ["À trier", "Bajapur", "Islande", "Japon 2024", "Japonaiseries", "Noël 2024", "Retour du Japon", "Viêt Nam"])
        #expect(titles("   ") == titles(""))
        #expect(PhotosAlbumSearch(tree: Self.tree).count == 8)
    }

    @Test func findsAnyPartOfATitleInEveryFolderWithoutCaseOrAccents() {
        #expect(titles("LAND") == ["Islande"])
        #expect(titles("viet") == ["Viêt Nam"])
        #expect(titles("noel") == ["Noël 2024"])
        #expect(titles("a trier") == ["À trier"])
        #expect(titles("zzz").isEmpty)
    }

    @Test func bestMatchesComeFirst() {
        // Start of the title, then start of a word, then anywhere.
        #expect(titles("jap") == ["Japon 2024", "Japonaiseries", "Retour du Japon", "Bajapur"])
    }

    @Test func everyWordMustBeFoundInTheTitleOrAFolder() {
        #expect(titles("2024 japon") == ["Japon 2024"])
        #expect(titles("2024") == ["Japon 2024", "Noël 2024"])
        // The name of a folder finds the albums in it, at any depth, after the titles that match.
        #expect(titles("voyages") == ["Islande", "Japon 2024", "Retour du Japon", "Viêt Nam"])
        #expect(titles("asie jap") == ["Japon 2024"])
        #expect(titles("famille japon").isEmpty)
    }

    @Test func titleMatchesComeBeforeFolderMatches() {
        let tree = [Self.folder("Japon", [Self.album("Kyoto")]), Self.album("Tout le Japon")]
        #expect(PhotosAlbumSearch(tree: tree).matches(for: "japon").map(\.album.title) == ["Tout le Japon", "Kyoto"])
    }

    @Test func matchesSayWhichFoldersTheAlbumIsIn() throws {
        let search = PhotosAlbumSearch(tree: Self.tree)
        #expect(try #require(search.matches(for: "japon 2024").first).folders == ["Voyages", "Asie"])
        #expect(try #require(search.matches(for: "trier").first).folders.isEmpty)
    }

    @Test func albumsOfTheSameTitleAreToldApartByFolder() {
        let tree = [Self.folder("2023", [.album(PhotosAlbum(id: "b", title: "Noël", kind: .user, estimatedCount: 0))]),
                    Self.folder("2022", [.album(PhotosAlbum(id: "a", title: "Noël", kind: .user, estimatedCount: 0))])]
        let matches = PhotosAlbumSearch(tree: tree).matches(for: "noel")
        #expect(matches.map(\.id) == ["a", "b"])
        #expect(matches.map(\.folders) == [["2022"], ["2023"]])
    }

    @Test func leavesTheExcludedAlbumOut() {
        #expect(titles("jap", excluding: "album-Japon 2024") == ["Japonaiseries", "Retour du Japon", "Bajapur"])
        #expect(PhotosAlbumSearch(tree: Self.tree, excluding: "album-Japon 2024").count == 7)
    }

    @MainActor
    @Test func pickerHighlightsTheBestMatchAndFollowsTheArrowKeys() {
        let model = PhotosAlbumPickerModel(tree: Self.tree)
        #expect(model.albumCount == 8)
        #expect(model.highlighted?.title == "À trier")

        model.query = "jap"
        #expect(model.matches.map(\.album.title) == ["Japon 2024", "Japonaiseries", "Retour du Japon", "Bajapur"])
        #expect(model.highlighted?.title == "Japon 2024")
        model.moveHighlight(by: -1)
        #expect(model.highlighted?.title == "Japon 2024", "stops at the top")
        model.moveHighlight(by: 1)
        model.moveHighlight(by: 1)
        #expect(model.highlighted?.title == "Retour du Japon")
        model.moveHighlight(by: 5)
        #expect(model.highlighted?.title == "Bajapur", "stops at the bottom")

        // Typing more starts again from the best match.
        model.query = "japo"
        #expect(model.highlighted?.title == "Japon 2024")
        model.query = "zzz"
        #expect(model.matches.isEmpty)
        #expect(model.highlighted == nil)
        model.moveHighlight(by: 1)
        #expect(model.highlighted == nil)
    }

    @MainActor
    @Test func pickerLeavesTheAlbumOnScreenOut() {
        let model = PhotosAlbumPickerModel(tree: Self.tree, excluding: "album-Islande")
        #expect(model.albumCount == 7)
        model.query = "islande"
        #expect(model.matches.isEmpty)
    }
}
