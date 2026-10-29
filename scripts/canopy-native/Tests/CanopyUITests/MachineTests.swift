import CanopyCore
import Foundation
import Testing
@testable import CanopyUI

/// The machine page and the dashboard over the installed app. Nothing here posts: a process write
/// (kill, restart, swap, reap, run main, stack up) is checked as the `Write` its command builds, and
/// kills are walked through their routes only — never dispatched, never against a server.
@MainActor @Suite struct MachineTests {
    func app(_ route: Route = .machine) throws -> (AppModel, Workstation) {
        var c = AppConfig()
        c.route = route
        let a = AppModel(config: c, port: 1, telemetry: false)
        let m = a.state { Workstation(app: a) }
        m.take(try JSONDecoder().decode(Previews.self, from: Data(MachineFixtures.previews.utf8)))
        return (a, m)
    }

    @Test func decodesTheLiveShapes() throws {
        let p = try JSONDecoder().decode(Previews.self, from: Data(MachineFixtures.previews.utf8))
        #expect(p.previews?.map(\.port) == ["3001", "3000", "3009"], "a numeric port reads as its string")
        #expect(p.substrate.doctor?.broken.first?.name == "docker")
        #expect(p.substrate.total == 2 && p.substrate.down)
        let f = try JSONDecoder().decode(Footprint.self, from: Data(MachineFixtures.footprint.utf8))
        #expect(f.machine.pressure == "ok" && f.repo.hygiene != nil && f.server.caches.count == 5)
        let empty = try JSONDecoder().decode(SchemaDrift.self, from: Data("{}".utf8))
        #expect(empty.pg == nil, "the live server sends schema {} when the stack is down")
    }

    @Test func driftInWords() {
        let sc = SchemaDrift(pg: .init(head: "x", behind: 2, ahead: 1, latestBehind: "20261028120000_add_col.sql", latestAhead: "9_mine.sql"),
                             ch: .init(head: "y", behind: 1, latestBehind: "z"))
        #expect(MachineText.drift(sc) == "missing 2 migrations (add_col) · 1 not in main (mine) · clickhouse 1 behind")
        #expect(MachineText.drift(SchemaDrift(pg: .init(head: "x", behind: 1, ahead: 0, latestBehind: "1_a.sql", latestAhead: ""))) == "missing 1 migration (a)")
        #expect(MachineText.drift(nil) == "")
        #expect(MachineText.service("loops-psql-1", project: "loops") == "psql")
        #expect(MachineText.service("loops-wt-psql-1", project: "loops-wt") == "psql")
        #expect(MachineText.ago(59 * 60) == "59m" && MachineText.ago(3 * 3600 + 120) == "3h 2m")
    }

    @Test func serversAreThePaneAndTheirScope() throws {
        let (a, m) = try app()
        #expect(a.rows == ["m:3001", "m:3000", "m:3009"])
        #expect(a.liveScopes() == [.server, .machine, .global])
        #expect(a.target(for: .server) == "3001")
        #expect(a.target(for: .machine) == "machine")
        #expect(m.main?.port == "3000")
        a.keys.handle("j")
        #expect(a.target(for: .server) == "3000")
    }

    @Test func retOpensTheUrlInTheBrowser() throws {
        let (a, m) = try app()
        var opened: [URL] = []
        m.openURL = { opened.append($0) }
        a.keys.handle("ret")
        #expect(opened == [URL(string: "http://localhost:3001")!])
        a.keys.handle("G")
        a.keys.handle("ret")
        #expect(opened.count == 1, "the stray has no url")
    }

    @Test func theLogIsAPaneOfItsOwn() throws {
        let (a, m) = try app()
        a.keys.handle("l")
        #expect(m.logFor == "3001")
        #expect(a.registry.command("machine.log.jobs")!.available!("3001"), "this server has a jobs worker")
        a.keys.handle("tab")
        #expect(m.logSrc == .jobs)
        m.take(log: "a\nb\nc")
        #expect(a.panes.map(\.id) == ["servers", "log"])
        a.keys.handle("C-w"); a.keys.handle("j")
        #expect(a.pane?.id == "log" && a.rows == ["log:0", "log:1", "log:2"])
        a.keys.handle("G")
        #expect(a.selected == "log:2")
        #expect(a.target(for: .server) == "3001", "in the log, server keys act on its server")
        a.keys.handle("h")
        #expect(m.logFor == nil && a.pane?.id == "servers")
        a.keys.handle("j"); a.keys.handle("j")
        #expect(!a.registry.command("machine.log")!.available!("3009"), "an unmanaged server has no log here")
    }

    @Test func killTakesASecondPressAndEscDisarms() throws {
        let (a, m) = try app()
        let kill = a.registry.command("machine.kill")!
        #expect(kill.route!("3001")?.id == "machine.kill.arm")
        a.keys.handle("X")
        #expect(m.armed == "kill 3001")
        #expect(kill.route!("3001")?.id == "machine.stop", "the second press sends")
        #expect(kill.route!("3000")?.id == "machine.kill.arm", "arming one server never arms another")
        a.keys.handle("esc")
        #expect(m.armed == nil)
        #expect(kill.route!("3001")?.id == "machine.kill.arm")

        let stop = try a.registry.command("machine.stop")!.write!("3001", nil)!
        #expect(stop.path == "/preview-kill" && stop.body == ["dir": "/Users/philbrockman/coding/loops-wt-1", "port": "3001"])
        #expect(!stop.settled(), "settled once the server is gone from /previews")
    }

    @Test func killAllAndReapArmToo() throws {
        let (a, m) = try app()
        a.keys.handle("space"); a.keys.handle("x")
        #expect(m.armed == "kill all")
        #expect(a.registry.command("machine.killall")!.route!("machine")?.id == "machine.stop.all")
        a.keys.handle("esc")
        a.keys.handle("space"); a.keys.handle("c")
        #expect(m.armed == "reap")
        #expect(a.registry.command("machine.reap")!.route!("machine")?.id == "machine.reap.confirm")
        let reap = try a.registry.command("machine.reap.confirm")!.write!("machine", nil)!
        #expect(reap.path == "/preview-reap" && reap.body == [:])
        #expect(m.armed == nil)
    }

    @Test func restartSwapMainAndStackBuildTheirWrites() throws {
        let (a, m) = try app()
        let restart = try a.registry.command("machine.restart")!.write!("3001", nil)!
        #expect(restart.path == "/preview-restart" && restart.body == ["dir": "/Users/philbrockman/coding/loops-wt-1", "port": "3001"])
        #expect(!a.registry.command("machine.restart")!.available!("3009"), "unmanaged: no restart")

        let swap = try a.registry.command("machine.swap")!.write!("3001", nil)!
        #expect(swap.body == ["port": "3001", "branch": "main"])
        #expect(m.swapped["3001"]?.label == "add-thing")
        let back = try a.registry.command("machine.swap")!.write!("3001", nil)!
        #expect(back.body == ["port": "3001", "dir": "/Users/philbrockman/coding/loops-wt-1"], "the second swap swings back")
        #expect(m.swapped["3001"] == nil)
        back.rollback?()
        #expect(m.swapped["3001"] != nil, "a refused swap puts the memory back")

        #expect(!a.registry.command("machine.main")!.available!("machine"), "main is already serving")
        #expect(a.registry.command("machine.stack")!.available!("machine"), "0/2 up")
        let stack = try a.registry.command("machine.stack")!.write!("machine", nil)!
        #expect(stack.path == "/stack-up" && stack.body == ["dir": "/Users/philbrockman/coding/loops"])
    }

    @Test func runMainTakesThePortTypedInInsertMode() throws {
        let (a, m) = try app()
        m.take(Previews(previews: [], substrate: m.substrate!))
        #expect(a.registry.command("machine.main")!.available!("machine"))
        a.keys.handle("i")
        #expect(a.keys.mode == .insert && a.insertField == MachinePage.portField)
        #expect(!a.keys.handle("4"), "digits go to the field")
        m.mainPort = " 3004 "
        a.keys.handle("esc")
        #expect(a.keys.mode == .normal)
        let w = try a.registry.command("machine.main")!.write!("machine", nil)!
        #expect(w.path == "/preview-main" && w.body == ["port": "3004"])
        #expect(!w.settled())
    }

    @Test func keyboardRule() throws {
        let (a, _) = try app()
        let v = KeyboardRule.violations(a) { $0.hasPrefix("machine.") || $0.hasPrefix("dashboard.") }
        #expect(v.isEmpty, "\(v)")
        #expect(a.registry.keyProblems.isEmpty, "\(a.registry.keyProblems)")
    }

    // ── the dashboard ──

    @Test func dashboardDecodesAndWalksItsTables() throws {
        var c = AppConfig()
        c.route = .dashboard
        let a = AppModel(config: c, port: 1, telemetry: false)
        let d = a.state { DashboardState(app: a) }
        let s = try JSONDecoder().decode(Summary.self, from: Data(MachineFixtures.summary.utf8))
        d.take(s)
        #expect(a.panes.map(\.id) == ["commands", "surfaces", "pairs", "most", "never", "weekly", "pages"])
        #expect(a.rows == ["cmd:0", "cmd:1", "cmd:2"])
        a.keys.handle("C-w"); a.keys.handle("j")
        #expect(a.pane?.id == "surfaces")
        a.keys.handle("C-w"); a.keys.handle("j"); a.keys.handle("C-w"); a.keys.handle("j")
        #expect(a.pane?.id == "most")
        a.keys.handle("C-w"); a.keys.handle("l")
        #expect(a.pane?.id == "never")
        #expect(DashText.pairP95(s.pairs[0].v1, kind: "cmd") == "—", "a v1 side that never ran")
        #expect(DashText.pairP95(s.pairs[1].v2, kind: "nav") == DashText.ms(s.surfaces[0].paint?.p95))
    }

    @Test func dashboardRangeCycles() throws {
        var c = AppConfig()
        c.route = .dashboard
        let a = AppModel(config: c, port: 1, telemetry: false)
        let d = a.state { DashboardState(app: a) }
        #expect(d.days == 30)
        a.keys.handle("space"); a.keys.handle("t")
        #expect(d.days == 90)
        a.keys.handle("space"); a.keys.handle("t")
        #expect(d.days == 7)
    }

    @Test func dashboardText() {
        #expect(DashText.ms(nil) == "—" && DashText.ms(16.7) == "17ms" && DashText.ms(8531.3) == "8.5s")
        #expect(DashText.pct(0) == "—" && DashText.pct(0.125) == "13%")
        #expect(DashText.ratio(30, 16.7).map(DashText.verdict) == "✕ 1.8×")
        #expect(DashText.ratio(10, 16.7).map(DashText.verdict) == "✓ in")
        #expect(DashText.ratio(10, nil) == nil)
    }
}
