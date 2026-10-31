import CanopyCore
import Foundation

/// The machine page's levers (commands/machine.ts, srv/preview.py): open a server, read its log,
/// restart it, swap its port to another build, kill it; run main, bring the stack up, reap the
/// orphans, kill them all. Every kill — one, all, the orphans — takes a second press, like a push.
@MainActor
enum MachineCommands {
    static func install(_ app: AppModel) {
        let r = app.registry
        let m = app.state { Workstation(app: app) }
        weak var wapp = app
        let owned: (String?) -> Bool = { [weak m] id in m?.server(id)?.owned ?? false }

        r.register(Command(id: "machine.open", title: "Open the server in the browser", scope: .server, verb: .main, label: "open",
                           available: { [weak m] id in m?.server(id)?.url != nil },
                           local: { [weak m] id, _ in
                               guard let m, let u = m.server(id)?.url, let url = URL(string: u) else { throw Refusal("no url") }
                               m.openURL(url)
                           }))
        r.register(Command(id: "machine.log", title: "Show the server's log", scope: .server, leader: LocalKey(",l"), label: "log", v1: ["click:log"],
                           available: { [weak m] id in owned(id) && m?.logFor != id },
                           local: { [weak m] id, _ in m?.showLog(id) }))
        r.register(Command(id: "machine.log.close", title: "Hide the log", scope: .server, verb: .out, label: "log", v1: ["click:hide log"],
                           available: { [weak m] _ in m?.logFor != nil },
                           local: { [weak m] _, _ in m?.showLog(nil) }))
        r.register(Command(id: "machine.log.jobs", title: "Switch the log between web and the jobs worker", scope: .server, verb: .face, label: "jobs",
                           v1: ["click:jobs worker", "click:web"],
                           available: { [weak m] id in m != nil && m!.logFor == id && m!.server(id)?.jobs == true },
                           local: { [weak m] id, _ in m.map { $0.showLog(id, $0.logSrc == .jobs ? .web : .jobs) } }))

        r.register(Command(id: "machine.restart", title: "Restart the server on its port", scope: .server, budget: .slowIO, leader: LocalKey(",r"), label: "restart",
                           v1: ["click:restart"], available: owned,
                           write: { [weak m] id, _ in
                               guard let s = m?.server(id) else { return nil }
                               return Write(path: "/preview-restart", body: ["dir": .string(s.dir), "port": .string(s.port)], settled: { true },
                                            said: "restarted \(s.label) on :\(s.port)", failed: "\(s.label) didn't restart")
                           }))

        r.register(Command(id: "machine.swap", title: "Swap the port to the branch's parent build, or back", scope: .server, budget: .slowIO,
                           leader: LocalKey(",w"), label: "swap",
                           available: { [weak m] id in
                               guard let m, owned(id), let id else { return false }
                               return m.swapped[id] != nil || m.server(id)?.swapTo != nil
                           },
                           write: { [weak m] id, _ in
                               guard let m, let s = m.server(id) else { return nil }
                               let before = m.swapped
                               let back = before[s.port]
                               if back != nil { m.swapped[s.port] = nil } else { m.swapped[s.port] = (s.dir, s.label) }
                               let body: JSONValue = back.map { ["port": .string(s.port), "dir": .string($0.dir)] }
                                   ?? ["port": .string(s.port), "branch": s.swapTo.map(JSONValue.string) ?? .null]
                               return Write(path: "/preview-swap", body: body, settled: { true },
                                            said: ":\(s.port) now serves \(back?.label ?? s.swapTo ?? "?")", failed: ":\(s.port) didn't swap",
                                            rollback: { [weak m] in m?.swapped = before })
                           }))

        // ── kill: arm, then send ──

        let killArm = { (id: String) in "kill \(id)" }
        r.register(Command(id: "machine.kill", title: "Kill the server", scope: .server, verb: .putAway, label: "kill",
                           available: { [weak m] id in m?.server(id) != nil },
                           route: { [weak m] id in
                               guard let m, let id, m.server(id) != nil else { return nil }
                               return RouteTo(m.armed == killArm(id) ? "machine.stop" : "machine.kill.arm", target: id)
                           }))
        r.register(Command(id: "machine.kill.arm", title: "Ready a kill (the next press sends it)", scope: .server, needsArg: true, quiet: true,
                           available: { [weak m] id in m?.server(id) != nil },
                           local: { [weak m] id, _ in m?.armed = id.map(killArm) }))
        r.register(Command(id: "machine.stop", title: "Kill a server", scope: .server, budget: .gitWrite, needsArg: true, v1: ["machine.kill"], quiet: true,
                           write: { [weak m] id, _ in
                               m?.armed = nil
                               guard let s = m?.server(id) else { return nil }
                               return Write(path: "/preview-kill", body: ["dir": .string(s.dir), "port": .string(s.port)],
                                            settled: { [weak m] in m?.server(id) == nil },
                                            said: "killed \(s.label)", failed: "\(s.label) is still running")
                           }))

        r.register(Command(id: "machine.killall", title: "Kill every server", scope: .machine, leader: LocalKey(",x"), label: "kill all",
                           available: { [weak m] _ in !(m?.servers.isEmpty ?? true) },
                           route: { [weak m] _ in
                               guard let m, !m.servers.isEmpty else { return nil }
                               return RouteTo(m.armed == "kill all" ? "machine.stop.all" : "machine.killall.arm")
                           }))
        r.register(Command(id: "machine.killall.arm", title: "Ready killing every server (the next press sends it)", scope: .machine,
                           needsArg: true, quiet: true,
                           local: { [weak m] _, _ in m?.armed = "kill all" }))
        r.register(Command(id: "machine.stop.all", title: "Kill every server", scope: .machine, needsArg: true, v1: ["click:kill all"], quiet: true,
                           local: { [weak m] _, _ in
                               guard let m else { return }
                               m.armed = nil
                               for s in m.servers { wapp?.runner.dispatch("machine.stop", via: .key, target: s.sid) }
                           }))

        r.register(Command(id: "machine.reap", title: "Reap orphaned servers (their worktree is gone)", scope: .machine, leader: LocalKey(",c"), label: "reap",
                           available: { [weak m] _ in !(m?.servers.isEmpty ?? true) },
                           route: { [weak m] _ in
                               guard let m, !m.servers.isEmpty else { return nil }
                               return RouteTo(m.armed == "reap" ? "machine.reap.confirm" : "machine.reap.arm")
                           }))
        r.register(Command(id: "machine.reap.arm", title: "Ready a reap (the next press sends it)", scope: .machine, needsArg: true, quiet: true,
                           local: { [weak m] _, _ in m?.armed = "reap" }))
        r.register(Command(id: "machine.reap.confirm", title: "Reap orphaned servers", scope: .machine, budget: .gitWrite, needsArg: true,
                           v1: ["click:reap orphaned"], quiet: true,
                           write: { [weak m] _, _ in
                               m?.armed = nil
                               return Write(path: "/preview-reap", body: [:], settled: { true }, said: "reaped", failed: "reap failed")
                           }))

        r.register(Command(id: "machine.main", title: "Run main (on the port beside it, else a free one)", scope: .machine, budget: .slowIO,
                           leader: LocalKey(",m"), label: "main", v1: ["click:▷ run main"],
                           available: { [weak m] _ in m != nil && m!.main == nil },
                           write: { [weak m] _, _ in
                               guard let m else { return nil }
                               return Write(path: "/preview-main", body: ["port": .string(m.mainPort.trimmingCharacters(in: .whitespacesAndNewlines))],
                                            settled: { [weak m] in m?.main != nil }, failed: "main didn't start")
                           }))
        // v2's port box beside "run main": type the port in insert mode, esc, then , m
        r.register(Command(id: "machine.port", title: "Type the port main runs on", scope: .machine, verb: .write, label: "port",
                           available: { [weak m] _ in m != nil && m!.main == nil },
                           local: { _, _ in wapp?.beginInsert(MachinePage.portField) }))

        r.register(Command(id: "machine.stack", title: "Start the shared Docker stack", scope: .machine, budget: .gitWrite, leader: LocalKey(",u"), label: "stack",
                           v1: ["click:▷ start stack"],
                           available: { [weak m] _ in
                               guard let s = m?.substrate else { return false }
                               return s.starting != true && s.down
                           },
                           write: { [weak m] _, _ in
                               Write(path: "/stack-up", body: ["dir": m?.substrate?.dir.map(JSONValue.string) ?? .null], settled: { true },
                                     said: "starting the stack", failed: "the stack didn't start")
                           }))

        // esc backs out of a readied kill before anything else on the page
        app.addCloser(isOpen: { [weak m] in m?.armed != nil }, close: { [weak m] in m?.armed = nil })
    }
}
