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
