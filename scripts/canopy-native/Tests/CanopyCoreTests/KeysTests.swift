import Foundation
import Testing
@testable import CanopyCore

@Suite struct KeysTests {
    // keys.test.ts, ported
    @Test func chordsAndScopes() {
        var km = Keymap([
            KeyBinding(id: "go.def", keys: ["g d"], scope: "review"),
            KeyBinding(id: "nav.dash", keys: ["g s"], scope: "global"),
            KeyBinding(id: "down", keys: ["j"], scope: "global"),
            KeyBinding(id: "review.down", keys: ["j"], scope: "review"),
        ])
        #expect(km.feed("j", scopes: ["global"]) == .run("down"))
        #expect(km.feed("j", scopes: ["review", "global"]) == .run("review.down"))
        #expect(km.feed("g", scopes: ["global"]) == .pending("g"))
        #expect(km.feed("d", scopes: ["global"]) == .none)
        #expect(km.feed("g", scopes: ["review", "global"]) == .pending("g"))
        #expect(km.feed("d", scopes: ["review", "global"]) == .run("go.def"))
        #expect(km.feed("x", scopes: ["global"]) == .none)
        #expect(km.feed("g", scopes: ["global"]) == .pending("g"))
        km.reset()
        #expect(km.feed("s", scopes: ["global"]) == .none)
    }

    @Test func keyNames() {
        #expect(KeyName.name(key: " ") == "space")
        #expect(KeyName.name(key: "Escape") == "esc")
        #expect(KeyName.name(key: "k", ctrl: true) == "C-k")
        #expect(KeyName.name(key: "a", alt: true) == "A-a")
        #expect(KeyName.name(key: "s", meta: true) == nil)
        #expect(KeyName.name(key: "Shift") == nil)
        #expect(KeyName.name(keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r", ctrl: false, meta: false, alt: false) == "ret")
        #expect(KeyName.name(keyCode: 5, characters: "G", charactersIgnoringModifiers: "G", ctrl: false, meta: false, alt: false) == "G")
        #expect(KeyName.name(keyCode: 40, characters: "\u{0B}", charactersIgnoringModifiers: "k", ctrl: true, meta: false, alt: false) == "C-k")
        #expect(KeyName.name(keyCode: 0, characters: "å", charactersIgnoringModifiers: "a", ctrl: false, meta: false, alt: true) == "A-a")
        #expect(KeyName.name(keyCode: 122, characters: "\u{F704}", charactersIgnoringModifiers: "\u{F704}", ctrl: false, meta: false, alt: false) == nil)
    }

    @Test func glyphs() {
        #expect(glyph("S") == "⇧s")
        #expect(glyph("g d") == "g d")
        #expect(glyph("C-k") == "⌃k")
        #expect(glyph("tab") == "⇥")
        #expect(glyph("space ?") == "space ?")
        #expect(shortTitle("Show outdated conversations — the ones GitHub hid") == "show outdated conversations")
    }

    // bindings.test.ts, ported
    @Test func validKeys() {
        #expect(Bindings.validKey("x"))
        #expect(Bindings.validKey("g d"))
        #expect(Bindings.validKey("C-k"))
        #expect(Bindings.validKey("space ?"))
        #expect(Bindings.validKey("C-space"))
        #expect(!Bindings.validKey("C-"))
        #expect(!Bindings.validKey("xx"))
        #expect(!Bindings.validKey(""))
    }

    @Test func verbOverridesReportProblems() {
        let r = Bindings.applyVerbKeys(["mark": ["v", "nope"], "zz": ["q"], "review.viewed": ["m"]], commands: ["review.viewed": [.mark]])
        #expect(r.keys.keys[.mark] == ["v"])
        #expect(r.customized == [.mark])
        #expect(r.problems == ["mark: not a key — \"nope\"", "zz: no such verb"])
        #expect(r.warnings.count == 1 && r.warnings[0].hasPrefix("review.viewed: keys belong to verbs now"))
        // `v` is select's: moving mark onto it breaks the table, and the table says so
        #expect(Bindings.tableProblems(r.keys) == ["v: select and mark"])
        #expect(Bindings.tableProblems(.defaults).isEmpty, "\(Bindings.tableProblems(.defaults))")
    }

    @Test func clashes() {
        let scopes = ["forests": ["row", "forests"], "review": ["line", "review"]]
        // the same move on two pages is fine
        #expect(Bindings.clashes([Bound(id: "cursor.down", scope: "global", keys: ["j"]), Bound(id: "review.down", scope: "review", keys: ["j"])], surfaceScopes: scopes).isEmpty)
        // a key meaning two things on two pages is not
        let bad = Bindings.clashes([Bound(id: "row.x", scope: "row", keys: ["x"]), Bound(id: "line.x", scope: "line", keys: ["x"])], surfaceScopes: scopes)
        #expect(bad == ["x: forests → row.x, review → line.x"])
        let twice = Bindings.clashes([Bound(id: "a", scope: "row", keys: ["q"]), Bound(id: "b", scope: "row", keys: ["q"])], surfaceScopes: scopes)
        #expect(twice.first == "q: a and b in one place")
        #expect(Bindings.clashes([Bound(id: "a", scope: "nowhere", keys: ["q"])], surfaceScopes: scopes) == ["a: scope nowhere is on no page"])
    }

    @Test func sheet() {
        let cmds = [
            SheetCmd(id: "row.go", title: "Go", scope: "row", keys: ["ret"], available: true),
            SheetCmd(id: "down", title: "Down", scope: "global", keys: ["j"], available: true),
            SheetCmd(id: "proj.x", title: "Archive", scope: "project", keys: ["x"], available: false),
        ]
        let s = sheetNow(surface: "forests", live: ["row", "forests", "global"], cmds: cmds, surfaceScopes: ["forests": ["project", "row", "forests"]])
        #expect(s.now.map(\.cmd.id) == ["row.go"])
        #expect(s.everywhere.map(\.cmd.id) == ["down"])
        #expect(s.notNow.map(\.cmd.id) == ["proj.x"])
    }

    @Test func pickRanking() {
        #expect(pickScore("abc", "") == 0)
        #expect(pickScore("xabc", "abc") == 1)
        #expect(pickScore("a_b_c", "abc") != nil)
        #expect(pickScore("cba", "abc") == nil)
        #expect(ranked(["a_b_c", "zabc", "nope"], "abc", { $0 }) == ["zabc", "a_b_c"])
    }
}

@MainActor @Suite struct ModeTests {
    @Test func bindingsLiveOnlyInTheirModes() {
        var km = Keymap([
            KeyBinding(id: "n.j", keys: ["j"], scope: "global"),
            KeyBinding(id: "i.ret", keys: ["ret"], scope: "global", modes: ["insert"]),
            KeyBinding(id: "both", keys: ["C-n"], scope: "global", modes: ["normal", "insert"]),
        ])
        #expect(km.feed("j", scopes: ["global"], mode: "insert") == .none)
        #expect(km.feed("ret", scopes: ["global"], mode: "normal") == .none)
        #expect(km.feed("ret", scopes: ["global"], mode: "insert") == .run("i.ret"))
        #expect(km.feed("C-n", scopes: ["global"], mode: "insert") == .run("both"))
    }

    @Test func clashesAreCheckedPerMode() {
        let scopes = ["forests": ["forests"]]
        let ok = Bindings.clashes([Bound(id: "a", scope: "global", keys: ["ret"]), Bound(id: "b", scope: "global", keys: ["ret"], modes: ["command"])], surfaceScopes: scopes)
        #expect(ok.isEmpty)
        let bad = Bindings.clashes([Bound(id: "a", scope: "global", keys: ["ret"], modes: ["menu"]), Bound(id: "b", scope: "global", keys: ["ret"], modes: ["menu"])], surfaceScopes: scopes)
        #expect(bad == ["menu: ret: a and b in one place"])
    }
}
