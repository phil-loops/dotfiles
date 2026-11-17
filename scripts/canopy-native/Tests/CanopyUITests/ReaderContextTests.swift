import CanopyCore
import Testing
@testable import CanopyUI

@MainActor struct ReaderContextTests {
    @Test func listCursorAwayAndBackDoesNotReviveAReaderEffect() throws {
        let app = try ModalTests().wikiApp()
        app.setCursor(try #require(app.rows.first))
        let origin = ReaderContext(app)
        let before = app.here()
        app.moveCursor(1)
        app.moveCursor(-1)
        #expect(before.sameSpot(app.here()))
        #expect(!origin.isCurrent(app))
    }

    @Test func anUnchangedCursorAndAnotherPaneKeepTheReaderCurrent() throws {
        let app = try ModalTests().wikiApp()
        app.setCursor(try #require(app.rows.first))
        let origin = ReaderContext(app)
        app.setCursor(app.selected)
        #expect(origin.isCurrent(app))
        let other = try #require(app.panes.first { $0.id != app.pane?.id })
        app.setCursor(try #require(other.rows.last), pane: other.id)
        #expect(origin.isCurrent(app))
    }

    @Test func unfocusedCursorWritesAreRememberedWhenThatPaneIsFocused() throws {
        let app = try ModalTests().wikiApp()
        let pane = try #require(app.pane)
        app.setCursor(try #require(pane.rows.first))
        let origin = ReaderContext(app)
        app.setCursor(try #require(pane.rows.last), pane: pane.id)
        app.setCursor(try #require(pane.rows.first), pane: pane.id)
        #expect(!origin.isCurrent(app))
    }

    @Test func fallbackRowAwayAndBackAlsoChangesTheReaderRevision() throws {
        let app = try ModalTests().wikiApp()
        app.cursor = nil
        app.cursorIdx = 0
        let origin = ReaderContext(app)
        app.cursorIdx = 1
        app.cursorIdx = 0
        #expect(!origin.isCurrent(app))
    }
}
