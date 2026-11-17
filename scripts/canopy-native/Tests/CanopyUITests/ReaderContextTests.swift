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

    @Test func aPickerOwnsExactlyItsNextClosingTransition() throws {
        let app = try ModalTests().wikiApp()
        var origin: ReaderContext?
        var accepted: [Bool] = []
        app.nav.pick("choose", [PickItem(label: "one")]) { _ in
            accepted.append(origin?.isCurrentAfterPickerChoice(app) == true)
        }
        origin = ReaderContext(app)
        #expect(app.nav.choose())
        #expect(accepted == [true])
        #expect(app.nav.reopen())
        #expect(app.nav.choose())
        #expect(accepted == [true, false])
    }

    @Test func leavingAndReturningToNormalModeRevokesTheReader() throws {
        let app = try ModalTests().wikiApp()
        let origin = ReaderContext(app)
        app.keys.openLayer(.sheet)
        app.keys.closeLayer()
        #expect(app.keys.active == .normal)
        #expect(!origin.isCurrent(app))
    }

    @Test func movingAwayAndBackDuringAPickerRevokesItsChoice() throws {
        let app = try ModalTests().wikiApp()
        app.setCursor(try #require(app.rows.first))
        var origin: ReaderContext?
        var accepted = true
        app.nav.pick("choose", [PickItem(label: "one")]) { _ in
            accepted = origin?.isCurrentAfterPickerChoice(app) == true
        }
        origin = ReaderContext(app)
        app.moveCursor(1)
        app.moveCursor(-1)
        #expect(app.nav.choose())
        #expect(!accepted)
    }
}
