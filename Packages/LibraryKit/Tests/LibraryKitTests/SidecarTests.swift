import Foundation
@testable import LibraryKit
import Testing

struct SidecarTests {
    private let recipe = Data(#"{"version":1,"exposure":0.5,"contrast":0,"saturation":-0.2}"#.utf8)

    private func temporaryImageURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("DSCF0001.RAF")
    }

    @Test func roundTripsThroughJSON() throws {
        let sidecar = Sidecar(rating: 4, flag: .picked, keywords: ["lapland", "winter"], recipeData: recipe)
        let data = try sidecar.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"version\" : 2"))
        #expect(text.contains("\"flag\" : \"pick\""))
        #expect(text.contains("\"exposure\" : 0.5"))

        let reloaded = try Sidecar(data: data)
        #expect(reloaded.id == sidecar.id)
        #expect(reloaded.rating == 4 && reloaded.flag == .picked && reloaded.keywords == ["lapland", "winter"])
        // The recipe comes back as canonical JSON: same content, keys sorted.
        let recipeObject = try JSONSerialization.jsonObject(with: #require(reloaded.recipeData)) as? [String: Any]
        #expect(recipeObject?["exposure"] as? Double == 0.5)
        #expect(recipeObject?["saturation"] as? Double == -0.2)
    }

    @Test func rejectsNewerVersionsAndGarbage() {
        let newer = Data(#"{"version":99,"id":"6F0E6C5A-0000-4000-8000-000000000000"}"#.utf8)
        #expect(throws: Sidecar.ReadError.unsupportedVersion(99)) { try Sidecar(data: newer) }
        #expect(throws: Sidecar.ReadError.self) { try Sidecar(data: Data("not json".utf8)) }
        #expect(throws: Sidecar.ReadError.self) { try Sidecar(data: Data(#"{"version":2,"id":"nope"}"#.utf8)) }
        // A bare recipe (the proof-of-concept format) is not a sidecar.
        #expect(throws: Sidecar.ReadError.self) { try Sidecar(data: recipe) }
    }

    @Test func writesNextToTheImageAndRemovesEmptyFiles() throws {
        let image = temporaryImageURL()
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
        #expect(try Sidecar.read(forImageAt: image) == nil)

        let sidecar = Sidecar(rating: 2)
        try sidecar.write(forImageAt: image)
        #expect(Sidecar.url(for: image).lastPathComponent == "DSCF0001.RAF.qaama")
        #expect(try Sidecar.read(forImageAt: image)?.id == sidecar.id)

        var cleared = sidecar
        cleared.rating = 0
        #expect(cleared.isEmpty)
        try cleared.write(forImageAt: image)
        #expect(try Sidecar.read(forImageAt: image) == nil)
    }

    @Test func omitsDefaultsInTheFile() throws {
        let text = try String(decoding: Sidecar(recipeData: recipe).jsonData(), as: UTF8.self)
        #expect(!text.contains("rating") && !text.contains("flag") && !text.contains("keywords"))
    }
}
