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

    @Test func oneQuestionMarkIsWhereYouAreWhatsOnScreenAndEveryKey() {
        let a = app()
        ExplainState.of(a).note(.init(id: "x", word: "to push", text: "commits only on this machine", rect: CGRect(x: 0, y: 10, width: 50, height: 12)))
        a.keys.handle("g"); a.keys.handle("?")
        #expect(a.sheetOpen, "one press")
        let m = KeySheet.model(a)
        #expect(m.entries.first == .heading("On screen", gold: false))
        #expect(m.entries.contains(.note(word: "to push", text: "commits only on this machine")))
        #expect(!m.whereNow.isEmpty, "where you are, even with nothing explained")
        a.keys.handle("?")
        #expect(!a.sheetOpen, "? again closes it")
    }

    @Test func withNothingExplainedTheSheetStillSaysWhereYouAre() {
        let a = app()
        a.keys.handle("g"); a.keys.handle("?")
        let m = KeySheet.model(a)
        #expect(a.sheetOpen && !m.whereNow.isEmpty)
        #expect(!m.entries.contains { if case .note = $0 { return true }; return false }, "no empty section")
    }

    @Test func typingFiltersTheNotesWithTheKeys() {
        let a = app()
        let e = ExplainState.of(a)
        e.note(.init(id: "p", word: "to push", text: "commits only on this machine", rect: CGRect(x: 0, y: 10, width: 50, height: 12)))
        e.note(.init(id: "d", word: "draft", text: "goes out when you open the PR", rect: CGRect(x: 0, y: 30, width: 50, height: 12)))
        a.keys.handle("g"); a.keys.handle("?")
        for k in ["m", "a", "c", "h"] { a.keys.handle(k) }
        #expect(KeySheet.model(a).notes.map(\.id) == ["p"])
    }

    @Test func aRepeatedNoteShowsOnceTopmostAndAGoneViewTakesItsNote() {
        let a = app()
        let e = ExplainState.of(a)
        e.note(.init(id: "b", word: nil, text: "local", rect: CGRect(x: 0, y: 40, width: 10, height: 10)))
        e.note(.init(id: "a", word: nil, text: "local", rect: CGRect(x: 0, y: 20, width: 10, height: 10)))
        e.note(.init(id: "c", word: nil, text: "draft", rect: CGRect(x: 0, y: 30, width: 10, height: 10)))
        #expect(e.shown.map(\.id) == ["a", "c"])
        e.drop("a")
        #expect(e.shown.map(\.id) == ["c", "b"])
    }
}
