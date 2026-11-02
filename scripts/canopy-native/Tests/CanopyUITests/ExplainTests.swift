import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

@MainActor @Suite struct ExplainTests {
    func app() -> AppModel {
        var c = AppConfig()
        c.route = .forests
        return AppModel(config: c, port: 1, telemetry: false)
    }

    @Test func questionMarkSaysWhatsOnScreenThenEveryKeyThenCloses() {
        let a = app()
        let e = ExplainState.of(a)
        e.note(.init(id: "x", text: "to push: commits only on this machine", rect: CGRect(x: 0, y: 10, width: 50, height: 12)))
        a.keys.handle("?")
        #expect(e.open && !a.sheetOpen, "the first ? is the notes")
        a.keys.handle("?")
        #expect(!e.open && a.sheetOpen, "the second is every key")
        a.keys.handle("?")
        #expect(!e.open && !a.sheetOpen)
        a.keys.handle("?")
        a.keys.handle("esc")
        #expect(!e.open, "esc closes the notes")
    }

    @Test func withNothingToExplainQuestionMarkIsTheKeySheet() {
        let a = app()
        a.keys.handle("?")
        #expect(!ExplainState.of(a).open && a.sheetOpen)
    }

    @Test func aRepeatedNoteShowsOnceTopmostAndAGoneViewTakesItsNote() {
        let a = app()
        let e = ExplainState.of(a)
        e.note(.init(id: "b", text: "local", rect: CGRect(x: 0, y: 40, width: 10, height: 10)))
        e.note(.init(id: "a", text: "local", rect: CGRect(x: 0, y: 20, width: 10, height: 10)))
        e.note(.init(id: "c", text: "draft", rect: CGRect(x: 0, y: 30, width: 10, height: 10)))
        #expect(e.shown.map(\.id) == ["a", "c"])
        e.drop("a")
        #expect(e.shown.map(\.id) == ["c", "b"])
    }
}
