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
        #expect(glyph("C-ret") == "⌃↵" && glyph("A-ret") == "⌥↵")
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

    /// keys-native.toml (verbs) over keys.toml (v2's): v2's command ids warn and name the verb and
    /// the file; a verb line in keys.toml still applies but warns, and the native file wins it.
    @Test func theNativeFileOverTheSharedOne() {
        let r = Bindings.applyVerbKeys(["mark": ["b"]],
                                       shared: ["review.viewed": ["m"], "put-away": ["D"], "mark": ["q"], "zz.top": ["z"], "zz": ["z"]],
                                       commands: ["review.viewed": [.mark]])
        #expect(r.keys.keys[.mark] == ["b"], "the native file wins")
        #expect(r.keys.keys[.putAway] == ["D"], "a verb line in keys.toml still applies")
        #expect(r.customized == [.mark, .putAway])
        #expect(r.problems.isEmpty, "keys.toml is v2's: nothing in it is a native problem — \(r.problems)")
        #expect(r.warnings.contains { $0.hasPrefix("review.viewed: keys belong to verbs now") && $0.contains("`mark = …` in keys-native.toml") })
        #expect(r.warnings.contains { $0.hasPrefix("put-away: a verb in keys.toml") && $0.contains("move it to keys-native.toml") })
        #expect(r.warnings.contains { $0.hasPrefix("mark: a verb in keys.toml") && $0.contains("keys-native.toml's line wins") })
        #expect(r.warnings.count == 5)
        #expect(KeysToml.nativePath.hasSuffix("/.dotfiles/canopy/keys-native.toml") && KeysToml.path.hasSuffix("/.dotfiles/canopy/keys.toml"))
    }

    @Test func clashes() {
        let scopes = ["forests": ["row", "project", "forests"], "review": ["line", "thread", "review"]]
        // the same verb on two pages is the point
        #expect(Bindings.clashes([Bound(id: "cursor.down", scope: "global", keys: ["j"], verbs: ["next"]),
                                  Bound(id: "review.down", scope: "review", keys: ["j"], verbs: ["next"])], surfaceScopes: scopes).isEmpty)
        // one leader key on two pages: each page's own namespace
        #expect(Bindings.clashes([Bound(id: "row.x", scope: "row", keys: [", x"], local: [", x"]),
                                  Bound(id: "line.x", scope: "line", keys: [", x"], local: [", x"])], surfaceScopes: scopes).isEmpty)
        // …but twice on one page, even from two scopes, or one swallowing another, is not
        #expect(Bindings.clashes([Bound(id: "row.x", scope: "row", keys: [", x"], local: [", x"]),
                                  Bound(id: "proj.x", scope: "project", keys: [", x"], local: [", x"])], surfaceScopes: scopes)
                == ["forests: , x is row.x and proj.x"])
        #expect(Bindings.clashes([Bound(id: "a", scope: "line", keys: [", b"], local: [", b"]),
                                  Bound(id: "b", scope: "review", keys: [", b p"], local: [", b p"])], surfaceScopes: scopes)
                == ["review: , b (a) swallows , b p (b)"])
        let twice = Bindings.clashes([Bound(id: "a", scope: "row", keys: ["q"]), Bound(id: "b", scope: "row", keys: ["q"])], surfaceScopes: scopes)
        #expect(twice.first == "q: a and b in one place")
        #expect(Bindings.clashes([Bound(id: "a", scope: "nowhere", keys: ["q"])], surfaceScopes: scopes) == ["a: scope nowhere is on no page"])
        // insert keeps its fixed set
        #expect(Bindings.clashes([Bound(id: "a", scope: "review", keys: ["A-1"], modes: ["insert"], verbs: ["nth-1"])], surfaceScopes: scopes)
                == ["insert: a adds to the fixed set (esc stops, ⌃↵ sends, ⌥↵ newline)"])
        #expect(Bindings.clashes([Bound(id: "a", scope: "review", keys: ["ret", "C-ret"], modes: ["insert"], verbs: ["send"])], surfaceScopes: scopes).isEmpty)
    }

    @Test func everyVerbHasAMeaningAndKeys() {
        for v in Verb.allCases {
            guard let spec = Verbs.byVerb[v] else { Issue.record("\(v) has no row in the table"); continue }
            let all = spec.keys + spec.entry
            #expect(!spec.meaning.isEmpty, "\(v) has no meaning")
            #expect(!all.isEmpty, "\(v) has no keys")
            for k in all { #expect(Bindings.validKey(k), "\(v): \(k)") }
            for k in spec.entry { #expect(k.count > 1, "\(v): \(k) is printable — it could never reach a text field") }
        }
        #expect(Verbs.table.count == Verb.allCases.count)
    }

    @Test func leaderKeysFollowTheLeader() {
        #expect(LocalKey(",c").key(leader: ",") == ", c")
        #expect(LocalKey(", b p").key(leader: ";") == "; b p")
        #expect(LocalKey(",S").description == ", S")
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
