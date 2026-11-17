import Foundation
@testable import LibraryKit
import Testing

/// The files of folder photos, moved and copied as photos. The files here are a few bytes each:
/// none of this looks at pixels. The trash is a folder, never the user's.
struct PhotoFilesTests {
    private func makeFolder() throws -> (root: URL, trash: FileTrash, trashURL: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoFilesTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let trashURL = base.appendingPathComponent("Trash")
        return (root, .folder(trashURL), trashURL)
    }

    private func write(_ name: String, in root: URL, bytes: [UInt8] = [1, 2, 3]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func anImageGoesToTheTrashWithItsSidecarAndBothComeBack() throws {
        let (root, trash, trashURL) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let edited = try write("edited.jpg", in: root)
        let plain = try write("plain.jpg", in: root)
        let sidecar = Sidecar(rating: 4, keywords: ["lapland"])
        try sidecar.write(forImageAt: edited)

        let trashed = PhotoFiles.trash(imagesAt: [edited, plain], into: trash)
        #expect(trashed.firstError == nil)
        #expect(trashed.images == [edited, plain])
        #expect(trashed.trashed.map(\.original.lastPathComponent) == ["edited.jpg", "edited.jpg.qaama", "plain.jpg"])
        #expect(names(in: root).isEmpty)
        #expect(names(in: trashURL) == ["edited.jpg", "edited.jpg.qaama", "plain.jpg"])

        let restored = PhotoFiles.restore(trashed.trashed)
        #expect(restored.firstError == nil)
        #expect(restored.images == [edited, plain], "sidecars come back with their image, and aren't photos")
        #expect(names(in: root) == ["edited.jpg", "edited.jpg.qaama", "plain.jpg"])
        #expect(try Sidecar.read(forImageAt: edited) == sidecar)
        #expect(names(in: trashURL).isEmpty)
    }

    @Test func aFileThatCanNotBeTrashedIsReportedAndLeavesTheOthersGo() throws {
        let (root, trash, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let here = try write("here.jpg", in: root)
        let gone = root.appendingPathComponent("gone.jpg")

        let outcome = PhotoFiles.trash(imagesAt: [gone, here], into: trash)
        #expect(outcome.images == [here])
        #expect(outcome.firstError != nil)
    }

    @Test func aFileWhosePlaceWasTakenStaysInTheTrash() throws {
        let (root, trash, trashURL) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let image = try write("a.jpg", in: root, bytes: [1])
        let trashed = PhotoFiles.trash(imagesAt: [image], into: trash)
        _ = try write("a.jpg", in: root, bytes: [2])

        let restored = PhotoFiles.restore(trashed.trashed)
        #expect(restored.images.isEmpty && restored.firstError != nil)
        #expect(try Data(contentsOf: image) == Data([2]), "the file that took its place is left alone")
        #expect(names(in: trashURL) == ["a.jpg"])
    }

    @Test func aFileRestoredIntoAFolderThatWasRemovedGetsItsFolderBack() throws {
        let (root, trash, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let trip = root.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: trip, withIntermediateDirectories: true)
        let image = try write("a.jpg", in: trip)
        let trashed = PhotoFiles.trash(imagesAt: [image], into: trash)
        try FileManager.default.removeItem(at: trip)

        #expect(PhotoFiles.restore(trashed.trashed).images == [image])
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func aCopyIsNamedAsTheFinderNamesOneAndGetsAnIdentityOfItsOwn() throws {
        let (root, _, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let image = try write("IMG_1.jpg", in: root, bytes: [7, 7])
        let sidecar = Sidecar(rating: 3, flag: .picked, keywords: ["winter"], recipeData: Data(#"{"version":1}"#.utf8))
        try sidecar.write(forImageAt: image)

        let first = try PhotoFiles.duplicate([image])
        #expect(first.map(\.lastPathComponent) == ["IMG_1 copy.jpg"])
        #expect(try Data(contentsOf: first[0]) == Data([7, 7]))
        let copied = try #require(try Sidecar.read(forImageAt: first[0]))
        #expect(copied.id != sidecar.id, "with the original's identifier, the catalog would take one file for the other")
        #expect(copied.rating == 3 && copied.flag == .picked && copied.keywords == ["winter"] && copied.recipeData == sidecar.recipeData)
        #expect(try Sidecar.read(forImageAt: image) == sidecar, "the original keeps its own")

        #expect(try PhotoFiles.duplicate([image]).map(\.lastPathComponent) == ["IMG_1 copy 2.jpg"])
        // A photo without decisions is copied without a sidecar.
        let plain = try write("plain.png", in: root)
        #expect(try PhotoFiles.duplicate([plain]).map(\.lastPathComponent) == ["plain copy.png"])
        #expect(!FileManager.default.fileExists(atPath: Sidecar.url(for: root.appendingPathComponent("plain copy.png")).path))
    }

    @Test func theImagesOfAPairAreCopiedUnderOneNameSoTheCopiesPairUp() throws {
        let (root, _, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let raw = try write("DSCF0001.RAF", in: root)
        let jpeg = try write("DSCF0001.jpg", in: root)
        // "DSCF0001 copy.jpg" is taken: the name must be free for both halves.
        _ = try write("DSCF0001 copy.jpg", in: root)

        let outcome = PhotoFiles.duplicate([[raw, jpeg]])
        #expect(outcome.firstError == nil)
        #expect(outcome.images.map(\.lastPathComponent) == ["DSCF0001 copy 2.RAF", "DSCF0001 copy 2.jpg"])
    }

    @Test func halfACopyIsNoCopy() throws {
        let (root, _, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let raw = try write("DSCF0002.RAF", in: root)
        let missing = root.appendingPathComponent("DSCF0002.jpg")

        let outcome = PhotoFiles.duplicate([[raw, missing]])
        #expect(outcome.images.isEmpty && outcome.firstError != nil)
        #expect(names(in: root) == ["DSCF0002.RAF"])
    }
}
