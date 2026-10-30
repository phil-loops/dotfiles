import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// The rules every area keeps, checked over the whole app as installed. A porter who adds a
/// command with a clashing key, or a surface twice, fails here.
@MainActor @Suite struct ShellTests {
    func app(_ route: Route = .forests) -> AppModel {
        var c = AppConfig()
        c.route = route
        return AppModel(config: c, port: 1, telemetry: false)
    }

    @Test func everySurfaceHasAPage() {
        let a = app()
        for s in Surface.all { #expect(a.surfaces[s.id] != nil, "no area registers surface \(s.id)") }
        #expect(a.installed == Areas.all.map { $0.name })
    }

    /// The verb table gives every key one meaning; this guards the table (after keys.toml), each
    /// page's leader namespace, nothing bound twice in one place, and insert's fixed set.
    @Test func keysMeanOneThingEverywhere() {
        let a = app()
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
        #expect(a.registry.keyWarnings.isEmpty)
    }

    /// Pages implement verbs or name a key under their leader; no page source spells a raw key.
    @Test func noPageSourceNamesARawKey() throws {
        let pages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/CanopyUI/Pages").standardized
        let files = FileManager.default.enumerator(at: pages, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        let raw = try NSRegularExpression(pattern: #"\bkeys:\s*(\[\s*"|NavKeys)|NavKeys\.|hint:\s*\[\s*"(ret|esc|tab|space|[A-Z]-\S+|.)""#)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in raw.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                Issue.record("\(f.lastPathComponent): \((text as NSString).substring(with: m.range)) — implement a verb or use LocalKey")
            }
        }
    }

    @Test func everyKeyIsAVerbsOrUnderTheLeader() {
        let a = app()
        let leader = a.registry.verbKeys.leader
        for c in a.registry.commands where !c.keys.isEmpty {
            #expect(!c.verbs.isEmpty || c.leader != nil, "\(c.id)")
            for k in c.keysByMode.values.flatMap({ $0 }) {
                let fromVerb = c.verbs.contains { v in c.modes.contains { a.registry.verbKeys.of(v, in: $0).contains(k) } }
                #expect(fromVerb || k.hasPrefix(leader + " "), "\(c.id): \(k)")
            }
        }
    }

    /// Within a page (all its scopes, one mode at a time) a leader key is one command, and no leader
    /// key swallows another.
    @Test func leaderNamespacesDontOverlapWithinAPage() {
        let a = app()
        for (surface, scopes) in a.registry.surfaceScopes {
            for mode in Set(a.registry.commands.flatMap(\.modes)) {
                var owner: [String: String] = [:]
                for c in a.registry.commands where c.leader != nil && scopes.contains(c.scope) && c.modes.contains(mode) {
                    let k = c.leader!.key(leader: ",")
                    #expect(owner[k] == nil || owner[k] == c.id, "\(surface): \(k) is \(owner[k] ?? "") and \(c.id)")
                    owner[k] = c.id
                }
                for k in owner.keys { for o in owner.keys where o != k { #expect(!o.hasPrefix(k + " "), "\(surface): \(k) swallows \(o)") } }
            }
        }
    }

    @Test func insertKeepsItsFixedSet() {
        let a = app()
        for c in a.registry.commands where c.modes.contains(.insert) && !(c.keysByMode[.insert] ?? []).isEmpty {
            #expect(c.verbs == [.send] && c.leader == nil, "\(c.id) adds to insert: \(c.verbs) \(String(describing: c.leader))")
        }
        #expect(Verb.send.spec.entry == ["ret", "C-ret"] && Verb.newline.spec.entry == ["A-ret"])
    }

    /// keys.toml moves a verb, and every page implementing it follows; the leader moves too.
    @Test func keysTomlOverridesApplyPerVerbAcrossPages() {
        let a = app()
        a.registry.applyUserKeys(["put-away": ["D"], "leader": [";"]])
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
        for id in ["project.archive", "todo.drop", "machine.kill", "tutor.forget", "review.pending.remove"] {
            #expect(a.registry.command(id)?.keys == ["D"], "\(id)")
        }
        #expect(a.registry.command("project.focus")?.keys == ["; f"])
        #expect(a.registry.command("review.split")?.keys == ["; s"])
        #expect(a.registry.customized == [.putAway, .leader])
        // onto a key another verb holds: the table says so
        a.registry.applyUserKeys(["put-away": ["m"]])
        #expect(a.registry.keyProblems.contains("m: mark and put-away"))
        // v2's command-id lines are warnings, never problems
        a.registry.applyUserKeys(["project.archive": ["x"]])
        #expect(a.registry.keyProblems.isEmpty && a.registry.keyWarnings.count == 1)
        #expect(a.registry.command("project.archive")?.keys == ["X"])
    }

    /// The two files end to end: keys.toml arrives in the server's bootstrap (v2's command ids, warned
    /// about), keys-native.toml is read from disk (verbs). Both from a temp dir and a stub — never
    /// Phil's real files or server.
    @Test func keysNativeTomlMovesVerbsAndKeysTomlStaysV2s() async throws {
        let port = 44901
        let html = #"<script>window.__VIEWER_REPOS__=["loops"];window.__CANOPY_KEYS__={"keys":{"project.archive":["x"]},"errors":[]};window.__CANOPY_ASSET__="a1"</script>"#
        ShipStub.answer(port, "GET", "/v2", html)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let native = dir.appendingPathComponent("keys-native.toml")
        try "# verbs\nput-away = \"D\"\nleader = [\";\"]\n".write(to: native, atomically: true, encoding: .utf8)
        let a = AppModel(config: AppConfig(), port: port, telemetry: false, protocolClasses: [ShipStub.self])
        a.nativeKeysPath = native.path
        #expect(a.nativeKeysPath != KeysToml.nativePath)
        await a.loadBootstrap()
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
        #expect(a.registry.command("project.archive")?.keys == ["D"], "the verb moved; v2's id line didn't")
        #expect(a.registry.command("project.focus")?.keys == ["; f"])
        #expect(a.registry.keyWarnings.count == 1 && a.registry.keyWarnings[0].contains("`put-away = …` in keys-native.toml"))
        // a bad native line is a problem of the native file's, named as such
        try "mark = 3\n".write(to: native, atomically: true, encoding: .utf8)
        a.applyKeyFiles()
        #expect(a.registry.keyProblems == ["keys-native.toml: mark: wants a key or a list of keys"])
        #expect(ShipStub.posts(port).isEmpty)
    }

    @Test func liveScopesEndWithTheSurfaceAndGlobal() {
        for s in Surface.all {
            let a = app(Route(s.path + (s.arg && !s.bare ? "/loops/x" : "")))
            let live = a.liveScopes()
            #expect(live.last == .global)
            #expect(live.contains(Scope(rawValue: s.id)), "\(s.id): \(live)")
        }
    }

    @Test func navCommandsRoute() {
        let a = app()
        a.keys.handle("g"); a.keys.handle("o")
        #expect(a.router.route == .todo)
        a.runner.dispatch("route.back", via: .menu)
        #expect(a.router.route == .forests)
        a.runner.dispatch("find.branch", via: .menu, arg: "loops:a/b")
        #expect(a.router.route == .review(repo: "loops", branch: "a/b"))
    }

    @Test func configParsing() {
        let c = AppConfig.parse(["--port", "62497", "--repo", "~/coding/loops", "/v2/b/loops/x", "--dump", "--dump-wait", "2", "-NSDocumentRevisionsDebugMode", "YES"])
        #expect(c.port == 62497)
        #expect(c.repo == "~/coding/loops")
        #expect(c.route == .review(repo: "loops", branch: "x"))
        #expect(c.dump && c.dumpWait == 2)
    }

    @Test func areaStateIsMadeOnce() {
        final class S { var n = 0 }
        let a = app()
        a.state { S() }.n += 1
        #expect(a.state { S() }.n == 1)
    }
}

/// The modal grammar, end to end through the real registry.
@MainActor @Suite struct ModalTests {
    func app(_ route: Route = .todo) -> AppModel {
        var c = AppConfig()
        c.route = route
        return AppModel(config: c, port: 1, telemetry: false)
    }

    @Test func everyCommandIsReachableByKey() {
        let a = app()
        #expect(KeyboardRule.violations(a).isEmpty, "\(KeyboardRule.violations(a))")
    }

    /// The wiki's real panes (its page list | the page's stops), from a saved /wiki-pages.
    func wikiApp() throws -> AppModel {
        let a = app(.wiki(slug: nil))
        a.state { WikiState() }.seed(try JSONDecoder().decode(PagesReply.self, from: Data(WikiFixture.pages.utf8)))
        return a
    }

    @Test func motionThroughPanes() throws {
        let a = try wikiApp()
        // focus starts on the first pane: the page list | the page's stops
        #expect(a.pane?.id == "pages")
        a.keys.handle("C-w"); a.keys.handle("l")
        #expect(a.pane?.id == "page")
        #expect(a.selected == a.rows.first)
        a.keys.handle("G")
        #expect(a.selected == a.rows.last)
        a.keys.handle("g"); a.keys.handle("g")
        #expect(a.selected == a.rows.first)
        a.keys.handle("j")
        #expect(a.cursorIdx == 1)
        a.keys.handle("C-w"); a.keys.handle("h")
        #expect(a.pane?.id == "pages")
        a.keys.handle("C-w"); a.keys.handle("l")
        #expect(a.cursorIdx == 1, "each pane keeps its own cursor")
    }

    @Test func selectModeExtendsFromTheAnchor() throws {
        let a = try wikiApp()
        a.focus(pane: "pages")
        a.keys.handle("j")
        a.keys.handle("v")
        #expect(a.keys.mode == .select)
        a.keys.handle("j"); a.keys.handle("j")
        #expect(a.selection.count == 3)
        a.keys.handle("esc")
        #expect(a.keys.mode == .normal)
        #expect(a.selection.count == 1)
    }

    @Test func escBacksOutOneLevelAtATime() {
        let a = app()
        a.keys.handle("?")
        #expect(a.keys.layer == .sheet)
        a.keys.handle("g")
        #expect(a.keys.pendingKeys.isEmpty, "g means nothing in the sheet layer")
        a.keys.handle("v")
        a.keys.handle("esc")
        #expect(a.keys.layer == nil && a.keys.mode == .normal)
        a.keys.handle("v")
        a.keys.handle("g")
        #expect(a.keys.pendingKeys == "g")
        a.keys.handle("esc")
        #expect(a.keys.pendingKeys.isEmpty && a.keys.mode == .select)
        a.keys.handle("esc")
        #expect(a.keys.mode == .normal)
    }

    @Test func colonRunsAFuzzyCompletion() {
        let a = app(.forests)
        a.keys.handle(":")
        #expect(a.keys.mode == .command)
        #expect(!a.keys.handle("x"), "printable keys go to the : field")
        a.cmdline = "go machne"
        #expect(a.completions.first?.id == "nav.machine")
        a.keys.handle("ret")
        #expect(a.keys.mode == .normal)
        #expect(a.router.route == .machine)
        a.keys.handle(":")
        a.cmdline = "route.back"
        a.keys.handle("ret")
        #expect(a.router.route == .forests)
    }

    @Test func insertModeLeavesTypingToTheField() {
        let a = app()
        a.beginInsert("note")
        #expect(a.keys.mode == .insert && a.insertField == "note")
        #expect(!a.keys.handle("j"))
        #expect(!a.keys.handle("space"))
        #expect(!a.keys.handle("g"))
        a.keys.handle("esc")
        #expect(a.keys.mode == .normal && a.insertField == nil)
    }

    /// ↵ follows the field: a newline in a many-line box (only ⌃↵ sends there), finishing in a
    /// one-line field; ⌃↵ sends in both; ⌥↵ is always the field's.
    @Test func retDependsOnTheFieldCtrlRetAlwaysSends() {
        let a = app()
        var sent = 0
        a.registry.register(Command(id: "test.send", title: "Send it", scope: .global, verb: .send, modes: [.insert],
                                    local: { _, _ in sent += 1 }))
        a.beginInsert("box", lines: .multi)
        #expect(a.keys.fieldLines == .multi)
        #expect(!a.keys.handle("ret"), "↵ goes to the box: a new line")
        #expect(sent == 0 && a.keys.mode == .insert && a.insertField == "box")
        #expect(!a.keys.handle("A-ret"), "⌥↵ is the field's newline")
        #expect(a.keys.handle("C-ret"))
        #expect(sent == 1)
        a.keys.handle("esc")
        #expect(a.keys.mode == .normal && a.keys.fieldLines == .single, "the kind ends with insert")

        a.beginInsert("line")
        #expect(a.keys.fieldLines == .single)
        #expect(a.keys.handle("ret"), "↵ finishes a one-line field")
        #expect(sent == 2)
        #expect(a.keys.handle("C-ret"))
        #expect(sent == 3)
        #expect(!a.keys.handle("A-ret"))
        #expect(Verb.send.spec.meaning.contains("⌃↵ always"))
    }

    @Test func menuIsALayerWithItsOwnKeys() {
        let a = app()
        a.keys.handle("space"); a.keys.handle("?")
        #expect(a.menuOpen && a.keys.active == .menu)
        #expect(!a.keys.handle("j"), "typing filters")
        #expect(a.keys.handle("down"))
        a.keys.handle("esc")
        #expect(!a.menuOpen)
    }

    @Test func retOpensTheRowOnForests() {
        let a = app(.forests)
        // no store data in a test: nothing to open, and ret says so rather than failing silently
        a.keys.handle("ret")
        #expect(a.router.route == .forests)
    }
}
