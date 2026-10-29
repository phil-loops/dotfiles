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
        #expect(all.first { $0.id == "nav.machine" }?.side == "g m")
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

    @Test func whatTheMenuFindsRunsWithItsArgument() {
        let a = app()
        a.state { WikiState() }.seed(PagesReply(pages: [WikiPage(slug: "canopy-v2-keys", title: "Keys like Helix", section: "Canopy v2")]))
        a.menuOpen = true
        let menu = a.state { MenuState() }
        menu.archived = FindWorld(branches: [.init(id: "loops:old/thing", name: "old/thing", project: "loops:old")], prs: [.init(id: "loops:old/thing", number: 4242)])
        menu.query = "4242"
        #expect(menu.rows(a).last == MenuRow(id: "find.branch", arg: "loops:old/thing", title: "old/thing", side: "#4242", group: "branches"))
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

    @Test func theSheetSaysWhatIsUnderTheCursorAndScrollsByKey() {
        let a = app(.todo)
        a.keys.handle("?")
        #expect(a.keys.layer == .sheet)
        let m = KeySheet.model(a)
        #expect(m.here == "the Todo page")
        #expect(m.everywhere.contains { $0.cmd.id == "nav.forests" && $0.key == "g f" })
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
        #expect(rows.contains { $0.key == "f" && $0.what == "go to Forests" })
        let ks: [String] = rows.map(\.key)
        let lower: [String] = ks.map { $0.lowercased() }
        #expect(lower == lower.sorted())
    }
}
