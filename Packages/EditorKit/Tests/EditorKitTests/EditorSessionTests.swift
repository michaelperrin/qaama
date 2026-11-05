import CoreImage
import EditModel
@testable import EditorKit
import Foundation
import LibraryKit
import RenderEngine
import Testing

@MainActor
struct EditorSessionTests {
    @Test func showingAnotherPhotoClosesThePreviousOneAndKeepsTheCanvas() async throws {
        let source = SampleLibrarySource(count: 3)
        let ids = source.assets.map(\.id)
        let renderer = try #require(CanvasRenderer())
        let session = EditorSession(assetID: ids[0], source: source, renderer: renderer)
        let undoManager = UndoManager()
        session.undoManager = undoManager
        let first = session.model
        await first.open()
        #expect(first.isOpen)
        #expect(renderer.image != nil)

        session.show(ids[1])
        let second = session.model
        #expect(second.assetID == ids[1])
        #expect(second !== first)
        #expect(second.renderer === renderer)
        #expect(second.undoManager === undoManager)
        #expect(first.isClosed)
        #expect(first.renderer == nil)

        // The photo left behind can no longer draw on the canvas it used to own.
        await second.open()
        let shown = try #require(renderer.image)
        first.recipe.global.exposure = 1
        first.commitChange()
        #expect(renderer.image === shown)
        second.recipe.global.exposure = 0.5
        #expect(renderer.image !== shown)
    }

    @Test func aPhotoClosedBeforeItFinishedOpeningNeverDraws() async throws {
        let source = SampleLibrarySource(count: 2)
        let ids = source.assets.map(\.id)
        let renderer = try #require(CanvasRenderer())
        let session = EditorSession(assetID: ids[0], source: source, renderer: renderer)
        let first = session.model
        session.show(ids[1])
        await first.open()
        #expect(!first.isOpen)
        #expect(renderer.image == nil)
    }

    @Test func neighborsFollowTheLibraryOrderAndShowingTheSamePhotoIsANoOp() {
        let source = SampleLibrarySource(count: 3)
        let ids = source.assets.map(\.id)
        let session = EditorSession(assetID: ids[0], source: source, renderer: nil)
        #expect(session.neighbor(offset: -1) == nil)
        #expect(session.neighbor(offset: 1) == ids[1])
        let model = session.model
        session.show(ids[0])
        #expect(session.model === model)
        #expect(!model.isClosed)
        session.show(ids[2])
        #expect(session.neighbor(offset: 1) == nil)
        #expect(session.neighbor(offset: -1) == ids[1])
        session.close()
        #expect(session.model.isClosed)
    }
}
