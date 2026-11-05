import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// find.test.ts, ported.
@Suite struct FindTests {
    let world = FindWorld(
        branches: [
            .init(id: "loops:dep-cleanup/remove-unused-deps", name: "dep-cleanup/remove-unused-deps", project: "loops:dep-cleanup"),
            .init(id: "loops:dep-cleanup/remove-unused-lint-directives", name: "dep-cleanup/remove-unused-lint-directives", project: "loops:dep-cleanup"),
            .init(id: "loops:old-thing/unused", name: "old-thing/unused", project: "loops:old-thing"),
        ],
        projects: [.init(id: "loops:dep-cleanup", name: "dep-cleanup", archived: false), .init(id: "loops:old-thing", name: "old-thing", archived: true)],
        prs: [.init(id: "loops:dep-cleanup/remove-unused-deps", number: 11130)])

    func ids(_ q: String, _ w: FindWorld? = nil) -> [String] { Finder.finds(q, w ?? world).map { "\($0.cmd):\($0.id)" } }

    @Test func nothingTypedFindsNothing() {
        #expect(ids("") == [])
        #expect(ids("  ") == [])
    }

    @Test func lettersInOrderFindABranchByName() {
        #expect(ids("rmunusdeps") == ["find.branch:loops:dep-cleanup/remove-unused-deps"])
        #expect(ids("unused lint") == ["find.branch:loops:dep-cleanup/remove-unused-lint-directives"])
        #expect(ids("zzz") == [])
    }

    @Test func aSubstringBeatsAScatterArchivedForestsBranchesComeLast() {
        #expect(ids("unused") == [
            "find.branch:loops:dep-cleanup/remove-unused-deps",
            "find.branch:loops:dep-cleanup/remove-unused-lint-directives",
            "find.branch:loops:old-thing/unused",
        ])
    }

    @Test func aForestsNameFindsTheForestAboveItsBranches() {
        #expect(ids("dep-cleanup").first == "find.forest:loops:dep-cleanup")
    }

    @Test func aPRNumberWithOrWithoutHashFindsItsBranch() {
        #expect(ids("11130") == ["find.branch:loops:dep-cleanup/remove-unused-deps"])
        #expect(ids("#11130") == ["find.branch:loops:dep-cleanup/remove-unused-deps"])
    }

    @Test func aBranchRowSaysItsPRAndForest() {
        let f = Finder.finds("11130", world)[0]
        #expect(f.title == "dep-cleanup/remove-unused-deps")
        #expect(f.sub == "#11130 · dep-cleanup")
    }

    @Test func aWikiPageIsFoundByTitleOrSlugNeverByAPRNumber() {
        var w = world
        w.pages = [.init(slug: "canopy-v2-keys", title: "Keys like Helix", section: "Canopy v2")]
        #expect(ids("keys like", w) == ["find.wiki:canopy-v2-keys"])
        #expect(ids("v2keys", w) == ["find.wiki:canopy-v2-keys"])
        #expect(ids("11130", w) == ["find.branch:loops:dep-cleanup/remove-unused-deps"])
        #expect(Finder.finds("helix", w)[0].sub == "wiki · Canopy v2")
    }

    @Test func aConceptIsFoundByItsName() {
        var w = world
        w.concepts = [.init(id: "one-runner-per-tick", name: "One runner per tick")]
        #expect(Finder.finds("one runner", w).map { "\($0.cmd):\($0.id):\($0.sub)" } == ["find.concept:one-runner-per-tick:concept"])
    }
}

/// sheet.test.ts and pick.test.ts, ported (the parts core's KeysTests don't already hold).
@MainActor @Suite struct SheetPickTests {
    func c(_ id: String, _ scope: String, _ keys: [String], _ available: Bool = true) -> SheetCmd { SheetCmd(id: id, title: id, scope: scope, keys: keys, available: available) }
    func keys(_ ls: [SheetLine]) -> String { ls.map { "\($0.key)=\($0.cmd.id)" }.joined(separator: " ") }
    let scopes = CommandRegistry.defaultSurfaceScopes.mapValues { $0.map(\.rawValue) }

    @Test func nowIsWhatTheCursorsThingCanDoNarrowestFirst() {
        let cmds = [
            c("forest.expand", "project", ["l", "right"]),
            c("branch.open", "branch", ["l", "right"]),
            c("branch.push", "branch", ["p"], false),
            c("project.archive", "project", ["X"]),
            c("ready.toggle", "forests", ["F"]),
            c("cursor.down", "global", ["j", "down"]),
            c("review.reply", "thread", ["r"]),
        ]
        let s = sheetNow(surface: "forests", live: ["branch", "project", "row", "forests", "global"], cmds: cmds, surfaceScopes: scopes)
        #expect(keys(s.now) == "l · right=branch.open X=project.archive F=ready.toggle")
        #expect(keys(s.everywhere) == "j · down=cursor.down")
        #expect(keys(s.notNow) == "l · right=forest.expand p=branch.push")
    }

    @Test func withNothingUnderTheCursorTheItemKeysWaitInNotNow() {
        let s = sheetNow(surface: "todo", live: ["todo", "global"], cmds: [c("todo.done", "item", ["D"]), c("nav.forests", "global", ["g f"])], surfaceScopes: scopes)
        #expect(keys(s.now) == "")
        #expect(keys(s.everywhere) == "g f=nav.forests")
        #expect(keys(s.notNow) == "D=todo.done")
    }

    @Test func keysReadUnambiguously() {
        #expect(glyph("S") == "⇧s")
        #expect(glyph("s") == "s")
        #expect(glyph("C-k") == "⌃k")
        #expect(glyph("tab") == "⇥")
        #expect(glyph("g D") == "g ⇧d")
        #expect(glyph("?") == "?")
    }

    @Test func thePickersFilterARunBeatsAScatter() {
        let rows = ["constructor constructor :6", "total function :20", "Circle class :12"]
        #expect(ranked(rows, "tot") { $0 } == ["total function :20", "constructor constructor :6"])
        #expect(ranked(rows, "crc") { $0 } == ["Circle class :12", "constructor constructor :6"])
        #expect(pickScore("area", "zz") == nil)
        #expect(ranked(rows, "  ") { $0 } == rows)
    }
}

@MainActor @Suite struct PaletteTests {
    func app(_ route: Route = .forests) -> AppModel {
        var c = AppConfig()
        c.route = route
        return AppModel(config: c, port: 1, telemetry: false)
    }

    /// A key is never shown without what it does, nor an action without its key: every button and every
    /// "<key> does X" hint in the sources names a command that has a key here.
    @Test func everyShownActionHasAKey() throws {
        let a = app()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"KeyButton\([^)]*?id: "([^"\\]+)"|keyOf\("([^"\\]+)"\)"#)
        var ids = Set<String>()
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
                for g in 1...2 where m.range(at: g).location != NSNotFound {
                    ids.insert((src as NSString).substring(with: m.range(at: g)))
                }
            }
        }
        #expect(ids.count > 20, "the scan finds the buttons and hints: \(ids.count)")
        let keyless = ids.filter { id in a.registry.command(id).map { $0.keys.isEmpty && $0.leader == nil } ?? false }
        #expect(keyless.isEmpty, "shown with no key: \(keyless.sorted())")
    }

    @Test func thePalettesCommandsAreAllReachableByKey() {
        let a = app()
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("menu.") || $0.hasPrefix("sheet.") || $0.hasPrefix("picker.") }.isEmpty)
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }

    @Test func groupsFollowTheWebApp() {
        #expect(MenuGroups.of("cursor.down") == "move")
        #expect(MenuGroups.of("nav.todo") == "go")
        #expect(MenuGroups.of("review.split") == "view")
        #expect(MenuGroups.of("branch.push") == "words & push")
        #expect(MenuGroups.of("wiki.forest") == "wiki")
        #expect(MenuGroups.of("machine.kill") == "machine")
        #expect(MenuGroups.of("review.reply") == "review")
    }

    @Test func spaceOpensTheMenuTypingFiltersRetRuns() {
        let a = app()
        a.keys.handle("space"); a.keys.handle("?")
        #expect(a.keys.layer == .menu)
        #expect(!a.keys.handle("m"), "printable keys go to the menu's filter")
        let menu = a.state { MenuState() }
        let all = menu.rows(a)
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { MenuGroups.order.contains($0.group) })
        // grouped in the palette's order, and every command shows its key
        let order = all.map { MenuGroups.order.firstIndex(of: $0.group)! }
        #expect(order == order.sorted())
        #expect(all.first { $0.id == "nav.machine" }?.side == "g ⇧m")
        menu.query = "go to machine"
        #expect(menu.rows(a).first?.id == "nav.machine")
        a.keys.handle("ret")
        #expect(a.keys.layer == nil)
        #expect(a.router.route == .machine)
    }

    @Test func theMenuWalksWithItsOwnKeys() {
        let a = app()
        a.menuOpen = true
        let menu = a.state { MenuState() }
        a.keys.handle("C-n"); a.keys.handle("down"); a.keys.handle("C-j")
        #expect(menu.index == 3)
        a.keys.handle("up")
        #expect(menu.index == 2)
        a.keys.handle("esc")
        #expect(!a.menuOpen)
    }

    /// The store holds archived forests too, so the finder reaches their branches by name or PR number.
    @Test func whatTheMenuFindsRunsWithItsArgument() {
        let a = world()
        a.state { WikiState() }.seed(PagesReply(pages: [WikiPage(slug: "canopy-v2-keys", title: "Keys like Helix", section: "Canopy v2")]))
        a.menuOpen = true
        let menu = a.state { MenuState() }
        #expect(menu.world(a).branches.contains { $0.id == "r:o" }, "the archived forest's branch")
        menu.query = "12"
        #expect(menu.rows(a).last == MenuRow(id: "find.branch", arg: "r:x", title: "x", side: "#12 · done", group: "branches"))
        menu.query = "keys like"
        let r = menu.rows(a).first { $0.group == "wiki pages" }
        #expect(r?.arg == "canopy-v2-keys")
        menu.index = menu.rows(a).firstIndex { $0.group == "wiki pages" }!
        a.keys.handle("ret")
        #expect(a.router.route == .wiki(slug: "canopy-v2-keys"))
    }

    @Test func conceptsAreFoundOnlyWhenSomethingCanOpenThem() {
        let a = app()
        let menu = a.state { MenuState() }
        menu.concepts = [.init(id: "one-runner-per-tick", name: "One runner per tick")]
        menu.query = "one runner"
        let found = menu.rows(a).contains { $0.id == "find.concept" }
        #expect(found == (a.registry.command("find.concept") != nil))
    }

    /// Typing while `?` is up narrows it in place: j/k scroll until something's typed, then type too;
    /// backspace edits, a synonym finds what the title doesn't say, ↵ runs the first match.
    /// Filtering shows each matching move with what it does; unfiltered, the moves stay one row of keys.
    @Test func aSearchSaysWhatEachMoveDoes() {
        let next = SheetLine(key: "g n", cmd: SheetCmd(id: "review.file.next", title: "Go to the next file", scope: "review", keys: ["g n"], available: true))
        func model(_ q: String) -> KeySheet.Model {
            KeySheet.Model(here: "this line", whereNow: "", notes: [], query: q, problems: [], warnings: [],
                           now: [], hints: [], everywhere: [], moves: [next], notNow: [], customized: [])
        }
        #expect(model("file").entries.contains(.line(next, dim: false)))
        #expect(!model("").entries.contains(.line(next, dim: false)))
        #expect(model("").entries.contains { if case .moves = $0 { return true }; return false })
    }

    @Test func typingFiltersTheSheetInPlace() {
        let a = app(.todo)
        a.keys.handle("g"); a.keys.handle("?")
        let sheet = a.state { SheetState() }
        a.keys.handle("j")
        #expect(sheet.top == 1 && sheet.query.isEmpty, "j still scrolls before anything's typed")
        for k in ["f", "o", "r", "e"] { a.keys.handle(k) }
        #expect(sheet.query == "fore" && sheet.top == 0)
        var m = KeySheet.model(a)
        #expect(m.everywhere.map(\.cmd.id).contains("nav.forests"))
        #expect(m.everywhere.allSatisfy { KeySheet.matches("fore", $0) })
        a.keys.handle("s"); a.keys.handle("t"); a.keys.handle("j")
        #expect(sheet.query == "forestj", "once filtering, j types")
        a.keys.handle("backspace")
        #expect(sheet.query == "forest")
        let line = { (id: String, title: String, key: String) in
            SheetLine(key: key, cmd: SheetCmd(id: id, title: title, scope: "review", keys: [key], available: true))
        }
        #expect(KeySheet.matches("diff", line("review.tab.files", "Show the code (the files tab)", "3")), "a synonym")
        #expect(KeySheet.matches("back", line("history.exit", "Back to the whole branch's code", "esc")))
        #expect(!KeySheet.matches("zzz", line("history.exit", "Back to the whole branch's code", "esc")))
        for _ in 0..<6 { a.keys.handle("backspace") }
        for k in ["g", "o", "space", "f", "o", "r", "e", "s", "t", "s"] { a.keys.handle(k) }
        m = KeySheet.model(a)
        let first = m.entries.lazy.compactMap { e -> String? in if case .line(let l, false) = e { return l.cmd.id }; return nil }.first
        #expect(first == "nav.forests", "\(String(describing: first))")
        a.keys.handle("ret")
        #expect(!a.sheetOpen && a.router.route == .forests, "↵ ran the first match: g F")
    }

    /// The Review page's own keys each say where they sit in `?` — a group, or a verb that implies
    /// one — so a new command can't fall back into one undifferentiated list.
    @Test func everyReviewKeyHasASheetGroup() {
        let a = app()
        for c in a.registry.commands where c.scope == .review && !c.keys.isEmpty {
            #expect(c.sheetGroup != nil, "\(c.id) (\(c.keys.joined(separator: " "))) has no group in the ? sheet")
        }
    }

    @Test func theSheetSaysWhatIsUnderTheCursorAndScrollsByKey() {
        let a = app(.todo)
        a.keys.handle("g"); a.keys.handle("?")
        #expect(a.keys.layer == .sheet)
        let m = KeySheet.model(a)
        #expect(m.here == "the Todo page")
        #expect(m.everywhere.contains { $0.cmd.id == "nav.forests" && $0.key == "g F" })
        #expect(m.entries.contains(.heading("Anywhere", gold: false)))
        let sheet = a.state { SheetState() }
        a.keys.handle("j"); a.keys.handle("j")
        #expect(sheet.top == 2)
        a.keys.handle("k")
        #expect(sheet.top == 1)
        a.keys.handle("C-d")
        #expect(sheet.top == min(13, m.entries.count - 1))
        a.keys.handle("?")
        #expect(a.keys.layer == nil)
    }

    @Test func thePickerTakesAnyItemsAndReopensWithItsQuery() {
        let a = app()
        var chosen: [Int] = []
        a.nav.pick("branches", ["alpha", "beta", "gamma"].map { PickItem(label: $0) }) { chosen.append($0) }
        #expect(a.keys.layer == .picker)
        #expect(!a.keys.handle("g"), "typing goes to the filter")
        a.nav.typed("gam")
        #expect(a.nav.shown.map(\.label) == ["gamma"])
        a.keys.handle("ret")
        #expect(chosen == [2], "the index is into the items, not the filtered list")
        #expect(a.keys.layer == nil)
        #expect(a.nav.reopen())
        #expect(a.keys.layer == .picker)
        #expect(a.nav.filter == "gam")
        a.nav.typed("")
        a.keys.handle("C-j"); a.keys.handle("C-j"); a.keys.handle("C-k")
        #expect(a.nav.index == 1)
        a.keys.handle("esc")
        #expect(a.nav.picker == nil && a.keys.layer == nil)
        #expect(chosen == [2])
    }

    @Test func theSheetNamesTheWikiPageUnderTheCursor() throws {
        let a = app(.wiki(slug: "hop-park"))
        let w = a.state { WikiState() }
        w.seed(try JSONDecoder().decode(PagesReply.self, from: Data(WikiFixture.pages.utf8)))
        w.arrive(a)
        #expect(KeySheet.model(a).here == w.page("hop-park")!.title)
    }

    @Test func whichKeyShowsWhatFollowsAPrefixHere() throws {
        let a = app(.wiki(slug: nil))
        a.keys.handle("g")
        let rows = a.keys.whichKeyRows()
        #expect(rows.contains { $0.key == "F" && $0.what == "go to Forests" })
        let order = KeySection.allCases.map(\.rawValue) + KeyGroup.allCases.map(\.rawValue)
        let ranks = rows.map { r in r.section.flatMap { order.firstIndex(of: $0) } ?? order.count }
        #expect(ranks == ranks.sorted(), "sections in order: \(rows.map { "\($0.section ?? "-") \($0.key)" })")
        for s in Set(rows.map(\.section)) {
            let lower = rows.filter { $0.section == s }.map { $0.key.lowercased() }
            #expect(lower == lower.sorted(), "letters sorted inside \(s ?? "-")")
        }
    }
}
