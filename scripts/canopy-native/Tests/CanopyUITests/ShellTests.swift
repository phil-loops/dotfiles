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

    @Test func keysMeanOneThingEverywhere() {
        let a = app()
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
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

    @Test func motionThroughAPlaceholderPane() {
        let a = app(.wiki(slug: nil))
        // the wiki placeholder: facts (1 row) | sources (5 rows); focus starts on the first pane
        #expect(a.pane?.id == "facts")
        a.keys.handle("C-w"); a.keys.handle("l")
        #expect(a.pane?.id == "sources")
        #expect(a.selected == a.rows.first)
        a.keys.handle("G")
        #expect(a.selected == a.rows.last)
        a.keys.handle("g"); a.keys.handle("g")
        #expect(a.selected == a.rows.first)
        a.keys.handle("j")
        #expect(a.cursorIdx == 1)
        a.keys.handle("C-w"); a.keys.handle("h")
        #expect(a.pane?.id == "facts")
        a.keys.handle("C-w"); a.keys.handle("l")
        #expect(a.cursorIdx == 1, "each pane keeps its own cursor")
    }

    @Test func selectModeExtendsFromTheAnchor() {
        let a = app(.wiki(slug: nil))
        a.focus(pane: "sources")
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
