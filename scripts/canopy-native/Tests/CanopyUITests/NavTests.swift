import CanopyCore
import CoreGraphics
import Foundation
import Testing
@testable import CanopyUI

/// The navigation core (NAV.md): its seams, the label layer, the jumplist, the pickers, the keymap deltas.
@MainActor @Suite struct NavSeamTests {
    func app(_ route: Route = .wiki(slug: nil)) -> AppModel {
        var c = AppConfig()
        c.route = route
        return AppModel(config: c, port: 1, telemetry: false)
    }

    /// What a PaneList would report for the rows of the wiki placeholder: facts | sources.
    func layOut(_ a: AppModel) {
        for p in a.panes {
            a.notePaneFrame(p.id, CGRect(x: Double(p.column) * 400, y: 0, width: 400, height: 300))
            for (i, r) in p.rows.enumerated() {
                a.noteTarget(LabelTarget(pane: p.id, key: r, rect: CGRect(x: Double(p.column) * 400, y: Double(i) * 20, width: 300, height: 18)))
            }
        }
    }

    @Test func reservedNavKeysAreHonored() {
        let a = app()
        for c in a.registry.commands {
            if let keys = NavKeys.reserved[c.id] { #expect(c.keys == keys, "\(c.id) binds \(c.keys), NAV.md decided \(keys)") }
            if NavKeys.jumps.contains(c.id) { #expect(c.recordsJump, "\(c.id) records a jump") }
        }
    }

    @Test func navAreaKeepsTheKeyboardRule() {
        let a = app()
        #expect(KeyboardRule.violations(a) { $0.hasPrefix("nav.") || $0.hasPrefix("pane.") || $0.hasPrefix("page.") }.isEmpty)
    }

    @Test func registeringAJumpIdFlagsIt() {
        let r = CommandRegistry()
        r.register(Command(id: "review.file.next", title: "x", scope: .review))
        r.register(Command(id: "review.other", title: "y", scope: .review))
        #expect(r.command("review.file.next")?.recordsJump == true)
        #expect(r.command("review.other")?.recordsJump == false)
    }

    @Test func paneRowsAreTargetsForFree() {
        let a = app()
        layOut(a)
        let t = a.provider!.targets(a)
        #expect(t.count == a.panes.reduce(0) { $0 + $1.rows.count })
        #expect(t.allSatisfy { $0.run == nil && !$0.title.isEmpty })
    }

    @Test func offScreenAndForeignRowsAreNotTargets() {
        let a = app()
        layOut(a)
        a.noteTarget(LabelTarget(pane: "sources", key: "src:gone.tsx", rect: CGRect(x: 400, y: 0, width: 10, height: 10)))
        a.noteTarget(LabelTarget(pane: "sources", key: a.panes[1].rows[0], rect: CGRect(x: 400, y: 900, width: 10, height: 10)))
        a.noteTarget(LabelTarget(pane: "tabs", key: "tab:x", rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        a.noteTarget(LabelTarget(pane: "tabs", key: "tab:y", rect: CGRect(x: 20, y: 0, width: 10, height: 10), run: RouteTo("nav.forests")))
        let keys = a.visibleTargets().map(\.key)
        #expect(!keys.contains("src:gone.tsx"), "a row its pane no longer holds")
        #expect(!keys.contains(a.panes[1].rows[0]), "scrolled out of its pane")
        #expect(!keys.contains("tab:x"), "a free target needs a run")
        #expect(keys.contains("tab:y"))
    }

    @Test func hereIsExact() {
        let a = app()
        a.focus(pane: "sources")
        a.keys.handle("j")
        let p = a.here()
        #expect(p.route == .wiki(slug: nil) && p.pane == "sources" && p.cursorKey == a.panes[1].rows[1])
    }
}

/// The label layer, driven by key names.
@MainActor @Suite struct LabelLayerTests {
    func app(_ route: Route = .wiki(slug: nil)) -> AppModel {
        var c = AppConfig()
        c.route = route
        return AppModel(config: c, port: 1, telemetry: false)
    }

    func layOut(_ a: AppModel, extra: Int = 0) {
        for p in a.panes {
            for (i, r) in p.rows.enumerated() {
                a.noteTarget(LabelTarget(pane: p.id, key: r, rect: CGRect(x: Double(p.column) * 400, y: Double(i) * 20, width: 300, height: 18)))
            }
        }
        for i in 0..<extra {
            a.noteTarget(LabelTarget(pane: "tabs", key: "tab:\(i)", rect: CGRect(x: Double(i) * 50, y: -30, width: 40, height: 18), run: RouteTo("nav.todo")))
        }
    }

    @Test func fAndGWOpenTheLayerAndALabelPicksThenExits() {
        let a = app()
        layOut(a)
        a.keys.handle("f")
        #expect(a.keys.active == .labels)
        let s = a.labeling!
        let last = a.panes[1].rows.last!
        let l = s.label("sources", last)!
        #expect(l.count == 1, "≤ 10 targets: one key")
        for ch in l { a.keys.handle(String(ch)) }
        #expect(a.keys.active == .normal && a.labeling == nil, "one pick, then the layer is gone")
        #expect(a.pane?.id == "sources" && a.selected == last)
        #expect(a.jumps.back.last?.pane == "facts", "a label pick is a jump")
        a.keys.handle("g"); a.keys.handle("w")
        #expect(a.keys.active == .labels)
    }

    @Test func labelsAreStableAcrossOpens() {
        let a = app()
        layOut(a, extra: 12)
        a.keys.handle("f")
        let first = a.labeling!.items.map(\.label)
        #expect(first.allSatisfy { $0.count == 2 }, "> 10 targets: two keys, the first picking the pane")
        #expect(Set(a.labeling!.items.filter { $0.pane == "facts" }.map { $0.label.first! }).count == 1)
        a.keys.handle("esc")
        #expect(a.keys.active == .normal)
        a.keys.handle("j")
        a.keys.handle("f")
        #expect(a.labeling!.items.map(\.label) == first, "moving the cursor doesn't reshuffle labels")
    }

    @Test func aPrefixWaitsAndAnythingElseCancels() {
        let a = app()
        layOut(a, extra: 12)
        a.keys.handle("f")
        let tab = a.labeling!.items.first { $0.pane == "tabs" }!.label
        a.keys.handle(String(tab.first!))
        #expect(a.keys.active == .labels && a.labeling?.typed.count == 1)
        a.keys.handle("z")
        #expect(a.keys.active == .normal && a.labeling == nil)
        #expect(a.router.route == .wiki(slug: nil))
        a.keys.handle("f")
        for ch in tab { a.keys.handle(String(ch)) }
        #expect(a.router.route == .todo, "a free target runs its command")
        #expect(a.jumps.back.count == 1, "one jump, not one per record point")
    }

    @Test func inSelectModeAPickExtendsTheRange() {
        let a = app()
        a.focus(pane: "sources")
        layOut(a)
        a.keys.handle("v")
        a.keys.handle("f")
        let l = a.labeling!.label("sources", a.panes[1].rows[3])!
        a.keys.handle(l)
        #expect(a.keys.mode == .select && a.selection.count == 4)
    }

    @Test func nothingToLabelSaysSo() {
        let a = app()
        a.keys.handle("f")
        #expect(a.keys.active == .normal && a.labeling == nil)
        a.runner.dispatch("nav.labels", via: .palette)
        #expect(a.runner.note == "nothing on screen to label")
    }
}

/// The app-wide jumplist and esc, through keys.
@MainActor @Suite struct HistoryTests {
    func app(_ route: Route = .wiki(slug: nil)) -> AppModel {
        var c = AppConfig()
        c.route = route
        return AppModel(config: c, port: 1, telemetry: false)
    }

    @Test func pageChangesRecordAndCORestoresPaneAndCursorExactly() {
        let a = app()
        a.focus(pane: "sources")
        a.keys.handle("j"); a.keys.handle("j")
        let spot = a.selected
        a.keys.handle("g"); a.keys.handle("o")
        #expect(a.router.route == .todo)
        a.keys.handle("g"); a.keys.handle("m")
        a.keys.handle("C-o")
        #expect(a.router.route == .todo)
        a.keys.handle("C-o")
        #expect(a.router.route == .wiki(slug: nil) && a.pane?.id == "sources" && a.selected == spot)
        a.keys.handle("C-i"); a.keys.handle("C-i")
        #expect(a.router.route == .machine)
        #expect(a.jumps.fwd.isEmpty)
    }

    @Test func aNewJumpAfterGoingBackTruncatesForward() {
        let a = app()
        a.keys.handle("g"); a.keys.handle("o")
        a.keys.handle("g"); a.keys.handle("m")
        a.keys.handle("C-o"); a.keys.handle("C-o")
        #expect(a.jumps.fwd.count == 2)
        a.keys.handle("g"); a.keys.handle("f")
        #expect(a.jumps.fwd.isEmpty)
        a.keys.handle("C-i")
        #expect(a.router.route == .forests, "nothing forward any more")
    }

    @Test func motionDoesntRecordButGGAndGDo() {
        let a = app()
        a.focus(pane: "sources")
        a.keys.handle("j"); a.keys.handle("j"); a.keys.handle("k")
        #expect(a.jumps.back.isEmpty, "j/k aren't jumps")
        a.keys.handle("G")
        #expect(a.jumps.back.count == 1)
        a.keys.handle("C-o")
        #expect(a.cursorIdx == 1)
    }

    @Test func cSSavesAndGAAlternates() {
        let a = app()
        a.keys.handle("C-s")
        #expect(a.jumps.back.count == 1)
        a.keys.handle("g"); a.keys.handle("o")
        a.keys.handle("g"); a.keys.handle("a")
        #expect(a.router.route == .wiki(slug: nil))
        a.keys.handle("g"); a.keys.handle("a")
        #expect(a.router.route == .todo, "g a again comes back")
    }

    @Test func codePlacesShareTheList() {
        let a = app()
        var at = Loc(repo: "loops", sha: "s", path: "a.ts", line: 1)
        var opened: [Loc] = []
        let detach = a.nav.attach(.init(open: { at = $0; opened.append($0) }, here: { at }))
        a.nav.go(Loc(repo: "loops", sha: "s", path: "b.ts", line: 9))
        #expect(a.jumps.back.last?.loc?.path == "a.ts")
        a.keys.handle("C-o")
        #expect(at.path == "a.ts" && opened.count == 2)
        detach()
    }

    @Test func escNeverChangesPage() {
        let a = app(.todo)
        a.registry.register(Command(id: "test.esc.leaves", title: "Leave", scope: .todo, keys: ["esc"], local: { [weak a] _, _ in a?.go(.forests) }))
        a.keys.handle("esc")
        #expect(a.router.route == .todo)
        #expect(a.runner.note == KeyEngine.nothingToCancel)
    }

    @Test func escWithNothingToCancelSaysWhereToGo() {
        let a = app()
        a.keys.handle("esc")
        #expect(a.router.route == .wiki(slug: nil))
        #expect(a.runner.note == KeyEngine.nothingToCancel)
    }
}
