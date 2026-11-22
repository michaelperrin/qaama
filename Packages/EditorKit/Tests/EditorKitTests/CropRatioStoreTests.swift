@testable import EditorKit
import Foundation
import Testing

struct CropRatioTests {
    @Test func readsWhatAUserTypes() {
        #expect(CropRatio(parsing: "7:5")?.name == "7:5")
        #expect(CropRatio(parsing: " 7 x 5 ")?.name == "7:5")
        #expect(CropRatio(parsing: "7×5")?.value == 1.4)
        #expect(CropRatio(parsing: "7/5")?.value == 1.4)
        #expect(CropRatio(parsing: "2,39:1")?.name == "2.39:1")
        #expect(CropRatio(parsing: "1.85")?.name == "1.85:1")
        #expect(CropRatio(parsing: "2:3")?.name == "2:3")
        #expect(CropRatio(parsing: "1:1")?.name == "Square")
    }

    @Test func takesTheNameTheUserGivesIt() throws {
        let paper = try #require(CropRatio(parsing: "297:210", label: "  A4 "))
        #expect(paper.name == "A4" && paper.label == "A4")
        // A blank name is no name.
        #expect(CropRatio(parsing: "7:5", label: "   ")?.name == "7:5")
        #expect(CropRatio(parsing: "7:5", label: "   ")?.label == nil)
        // Same name, two frames: still told apart.
        #expect(CropRatio(parsing: "2:1", label: "A4")?.id != paper.id)
    }

    @Test func aRatioWithoutANameIsReadBack() throws {
        let data = Data(#"[{"width": 7, "height": 5}, {"width": 297, "height": 210, "label": "A4"}]"#.utf8)
        #expect(try JSONDecoder().decode([CropRatio].self, from: data).map(\.name) == ["7:5", "A4"])
    }

    @Test func refusesWhatIsNotARatio() {
        for text in ["", "abc", "7:", ":5", "7:5:3", "0:5", "7:0", "-3:2", "100:1", "1:100", "inf:1", "nan"] {
            #expect(CropRatio(parsing: text) == nil, "\(text)")
        }
    }

    @Test func namesAValueWithoutItsNumbers() {
        #expect(CropRatio.name(forValue: 5.0 / 3) == "1.67:1")
        #expect(CropRatio.name(forValue: 2) == "2:1")
    }

    @Test func matchesWithinTheTolerance() throws {
        let ratio = try #require(CropRatio(width: 3, height: 2))
        #expect(ratio.matches(6000.0 / 4000))
        #expect(ratio.matches(1.5004))
        #expect(!ratio.matches(1.51))
    }

    @Test func decodingRefusesAnUnusableRatio() throws {
        let data = Data(#"[{"width": 3, "height": 0}]"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([CropRatio].self, from: data) }
    }
}

@MainActor
struct CropRatioStoreTests {
    /// A store on a file of a temporary folder, removed after `body`.
    private func withStore(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("nested/Crop Ratios.json"))
    }

    @Test func addsKeepsOrderAndReloads() throws {
        try withStore { url in
            let store = CropRatioStore(fileURL: url)
            #expect(store.ratios.isEmpty)
            let cinema = try #require(CropRatio(parsing: "2.39:1"))
            let print = try #require(CropRatio(parsing: "7:5"))
            #expect(try store.add(cinema) == cinema)
            #expect(try store.add(print) == print)
            #expect(store.ratios == [cinema, print])
            #expect(CropRatioStore(fileURL: url).ratios == [cinema, print])
        }
    }

    @Test func neverListsTheSameFrameTwice() throws {
        try withStore { url in
            let store = CropRatioStore(fileURL: url)
            // 6:4 is the built-in 3:2.
            #expect(try store.add(#require(CropRatio(parsing: "6:4"))).name == "3:2")
            #expect(store.ratios.isEmpty)
            let print = try store.add(#require(CropRatio(parsing: "7:5")))
            #expect(try store.add(#require(CropRatio(parsing: "14:10"))) == print)
            #expect(store.ratios == [print])
            // The upright frame is another one.
            try store.add(#require(CropRatio(parsing: "5:7")))
            #expect(store.ratios.map(\.name) == ["7:5", "5:7"])
        }
    }

    @Test func namesAreKeptAndRenameTheUsersOwnRatios() throws {
        try withStore { url in
            let store = CropRatioStore(fileURL: url)
            try store.add(#require(CropRatio(parsing: "7:5")))
            try store.add(#require(CropRatio(parsing: "297:210", label: "A4")))
            #expect(CropRatioStore(fileURL: url).ratios.map(\.name) == ["7:5", "A4"])
            // The same frame under a name: the listed one takes the name, where it is.
            #expect(try store.add(#require(CropRatio(parsing: "14:10", label: "Print"))).name == "Print")
            #expect(store.ratios.map(\.name) == ["Print", "A4"])
            #expect(store.ratios.first?.width == 7)
            // Without a name, the listed one is used as it is.
            #expect(try store.add(#require(CropRatio(parsing: "7:5"))).name == "Print")
            // Built-in ratios keep their name.
            #expect(try store.add(#require(CropRatio(parsing: "3:2", label: "Film"))).name == "3:2")
            #expect(CropRatioStore(fileURL: url).ratios.map(\.name) == ["Print", "A4"])
        }
    }

    @Test func findsTheListedRatioOfAValue() throws {
        try withStore { url in
            let store = CropRatioStore(fileURL: url)
            try store.add(#require(CropRatio(parsing: "7:5")))
            #expect(store.listed(matching: 16.0 / 9)?.name == "16:9")
            #expect(store.listed(matching: 1.4)?.name == "7:5")
            #expect(store.listed(matching: 1.7) == nil)
        }
    }

    @Test func removes() throws {
        try withStore { url in
            let store = CropRatioStore(fileURL: url)
            let print = try store.add(#require(CropRatio(parsing: "7:5")))
            let cinema = try store.add(#require(CropRatio(parsing: "2.39:1")))
            try store.remove(print)
            #expect(store.ratios == [cinema])
            #expect(CropRatioStore(fileURL: url).ratios == [cinema])
        }
    }

    @Test func anUnreadableFileGivesAnEmptyList() throws {
        try withStore { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: url)
            #expect(CropRatioStore(fileURL: url).ratios.isEmpty)
        }
    }
}
