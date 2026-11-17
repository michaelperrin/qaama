@testable import LibraryKit
import Testing

struct VisitTrailTests {
    @Test func goingBackReturnsWhereTheVisitWasMadeFromAndHowItWasLeft() {
        var trail = VisitTrail<String, Int>()
        #expect(trail.origin(of: "album") == nil && trail.goBack(from: "album") == nil)

        trail.visit("album", from: "photos", leaving: 42)
        #expect(trail.origin(of: "album") == "photos")
        #expect(trail.origin(of: "photos") == nil, "only the place reached has a way back")

        let back = trail.goBack(from: "album")
        #expect(back?.origin == "photos" && back?.place == 42)
        #expect(trail.count == 0 && trail.goBack(from: "album") == nil)
    }

    @Test func visitsMadeOneFromTheOtherAreRetracedLastFirst() {
        var trail = VisitTrail<String, Int>()
        trail.visit("iceland", from: "photos", leaving: 1)
        trail.visit("portfolio", from: "iceland", leaving: 2)

        #expect(trail.goBack(from: "portfolio")?.place == 2)
        trail.moved(to: "iceland")
        #expect(trail.origin(of: "iceland") == "photos")
        #expect(trail.goBack(from: "iceland")?.place == 1)
        trail.moved(to: "photos")
        #expect(trail.count == 0)
    }

    @Test func goingElsewhereForgetsTheTrail() {
        var trail = VisitTrail<String, Int>()
        trail.visit("iceland", from: "photos", leaving: 1)
        trail.moved(to: "iceland")
        #expect(trail.count == 1, "arriving where the visit leads keeps it")

        // The sidebar is used: coming back to the album later offers no way back.
        trail.moved(to: "folder")
        #expect(trail.count == 0 && trail.origin(of: "iceland") == nil)
    }

    @Test func aVisitMadeFromOffTheTrailStartsANewOne() {
        var trail = VisitTrail<String, Int>()
        trail.visit("iceland", from: "photos", leaving: 1)
        trail.visit("portfolio", from: "folder", leaving: 2)

        #expect(trail.count == 1)
        #expect(trail.goBack(from: "portfolio")?.origin == "folder")
    }
}
