import Foundation
import ImageIOKit
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

    @Test func aCorrectedCaptureDateIsKeptToTheSecondAsAUTCInstant() throws {
        let corrected = try #require(ISO8601DateFormatter().date(from: "2026-10-29T13:03:12Z"))
        var sidecar = Sidecar(captureDate: corrected.addingTimeInterval(0.7))
        #expect(sidecar.captureDate == corrected, "sub-seconds are dropped")
        #expect(!sidecar.isEmpty, "a correction alone is worth a file")
        let data = try sidecar.jsonData()
        #expect(String(decoding: data, as: UTF8.self).contains("\"captureDate\" : \"2026-10-29T13:03:12Z\""))
        #expect(try Sidecar(data: data).captureDate == corrected)

        sidecar.captureDate = nil
        #expect(sidecar.isEmpty)
        #expect(try !String(decoding: sidecar.jsonData(), as: UTF8.self).contains("captureDate"))
    }

    @Test func anAssignedLocationIsKeptInDecimalDegrees() throws {
        let etretat = GeoCoordinate(latitude: 49.7073, longitude: 0.2036)
        var sidecar = Sidecar(location: .place(etretat))
        #expect(!sidecar.isEmpty, "a location alone is worth a file")
        let data = try sidecar.jsonData()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let location = try #require(object["location"] as? [String: Double])
        #expect(location == ["latitude": 49.7073, "longitude": 0.2036])
        #expect(try Sidecar(data: data).location == .place(etretat))

        // A photo said to have no location, whatever its file says.
        sidecar.location = .removed
        #expect(!sidecar.isEmpty)
        let removed = try sidecar.jsonData()
        #expect(String(decoding: removed, as: UTF8.self).contains("\"location\" : \"none\""))
        #expect(try Sidecar(data: removed).location == .removed)

        sidecar.location = nil
        #expect(sidecar.isEmpty)
        #expect(try !String(decoding: sidecar.jsonData(), as: UTF8.self).contains("location"))

        // A position out of range, or half of one, is no position.
        let id = UUID().uuidString
        let outOfRange = Data(#"{"version":2,"id":"\#(id)","location":{"latitude":91,"longitude":2}}"#.utf8)
        #expect(try Sidecar(data: outOfRange).location == nil)
        let half = Data(#"{"version":2,"id":"\#(id)","location":{"latitude":48.8}}"#.utf8)
        #expect(try Sidecar(data: half).location == nil)
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
