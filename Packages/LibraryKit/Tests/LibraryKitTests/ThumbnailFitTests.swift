import CoreGraphics
@testable import LibraryKit
import Testing

struct ThumbnailFitTests {
    @Test func fitAsksForTheSquareItself() {
        #expect(ThumbnailFit.fit.requestSize(forSquare: 320, aspectRatio: 1.5) == CGSize(width: 320, height: 320))
        #expect(ThumbnailFit.fit.requestSize(forSquare: 320, aspectRatio: 0.5) == CGSize(width: 320, height: 320))
    }

    @Test func fillAsksForAShortEdgeEqualToTheSquare() {
        #expect(ThumbnailFit.fill.requestSize(forSquare: 320, aspectRatio: 1.5) == CGSize(width: 480, height: 320))
        #expect(ThumbnailFit.fill.requestSize(forSquare: 320, aspectRatio: 2 / 3) == CGSize(width: 320, height: 480))
        #expect(ThumbnailFit.fill.requestSize(forSquare: 320, aspectRatio: 1) == CGSize(width: 320, height: 320))
    }

    @Test func fillCapsPanoramasAndTreatsUnknownAsSquare() {
        #expect(ThumbnailFit.fill.requestSize(forSquare: 100, aspectRatio: 12) == CGSize(width: 400, height: 100))
        #expect(ThumbnailFit.fill.requestSize(forSquare: 100, aspectRatio: 0.05) == CGSize(width: 100, height: 400))
        #expect(ThumbnailFit.fill.requestSize(forSquare: 100, aspectRatio: 0) == CGSize(width: 100, height: 100))
    }

    @Test func displaySizeKeepsTheShapeOnlyWhenFitting() {
        #expect(ThumbnailFit.fill.displaySize(inSquare: 160, aspectRatio: 1.5) == CGSize(width: 160, height: 160))
        #expect(ThumbnailFit.fit.displaySize(inSquare: 160, aspectRatio: 1.5).width == 160)
        #expect(abs(ThumbnailFit.fit.displaySize(inSquare: 160, aspectRatio: 1.5).height - 160 / 1.5) < 0.001)
        #expect(ThumbnailFit.fit.displaySize(inSquare: 160, aspectRatio: 0.5) == CGSize(width: 80, height: 160))
        #expect(ThumbnailFit.fit.displaySize(inSquare: 160, aspectRatio: 0) == CGSize(width: 160, height: 160))
    }
}
