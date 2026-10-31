import CanopyCore
import SwiftUI

/// The machine (/v2/machine: previews, servers, footprint, logs; the `procs` pulse) and the
/// dashboard (/v2/dashboard: telemetry vs budgets).
enum MachineArea: PageArea {
    static let name = "machine"

    static func install(_ app: AppModel) {
        app.addSurface(MachineSurface())
        app.addSurface(DashboardSurface())
        MachineCommands.install(app)
        DashboardCommands.install(app)
    }
}

struct MachineSurface: SurfaceProvider {
    let surfaceID = "machine"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(MachinePage()) }

    /// The servers; and, while one's log is open, its lines as a second pane below (C-w j) so the
    /// log scrolls by keys like any list.
    func panes(_ app: AppModel) -> [Pane] {
        let m = app.state { Workstation(app: app) }
        var out = [Pane(id: "servers", title: "serving", rows: m.servers.map { RowKey.server($0.sid) })]
        if m.logFor != nil { out.append(Pane(id: "log", title: "log", rows: m.logLines.indices.map { "log:\($0)" }, row: 1, pageSize: 20)) }
        return out
    }

    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        RowKey.id(row, "m").map { RouteTo("machine.open", target: $0) }
    }

    func scopes(_ app: AppModel) -> [Scope] {
        target(for: .server, app) != nil ? [.server] : []
    }

    /// The server under the cursor; in the log pane, the server whose log it is.
    func target(for scope: Scope, _ app: AppModel) -> String? {
        guard scope == .server else { return nil }
        let m = app.state { Workstation(app: app) }
        if app.pane?.id == "log" { return m.logFor }
        guard let id = RowKey.id(app.selected, "m"), m.server(id) != nil else { return nil }
        return id
    }
}

private struct Health {
    var word: String
    var dot: KeyPath<Theme, Color>
    var text: KeyPath<Theme, Color>
    var breathe = false
    var faded = false
}

private let HEALTH: [String: Health] = [
    "healthy": Health(word: "healthy", dot: \.add, text: \.inkFaint),
    "compiling": Health(word: "compiling", dot: \.ember, text: \.ember, breathe: true),
    "starting": Health(word: "starting", dot: \.ember, text: \.ember, breathe: true),
    "error": Health(word: "error", dot: \.del, text: \.del),
    "wedged": Health(word: "not responding", dot: \.del, text: \.del),
    "dead": Health(word: "dead", dot: \.inkFaint, text: \.inkFaint, faded: true),
    "orphaned": Health(word: "orphaned", dot: \.inkFaint, text: \.inkFaint, faded: true),
]

/// Machine.tsx: every dev server this workstation runs, the one shared stack they all read and
/// write, and what the tooling costs the box. A server row says where it stands in a dot and a
/// word; its levers show on the cursor row; every kill takes a second press.
struct MachinePage: View {
    static let portField = "machine.port"
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var stop: (() -> Void)?

    var body: some View {
        let m = app.state { Workstation(app: app) }
        Group {
            if m.substrate == nil {
                Text("taking stock…").foregroundStyle(theme.inkFaint).padding(.horizontal, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                FollowScroll(panes: ["servers", "log"]) {
                    VStack(alignment: .leading, spacing: 32) {
                        Servers()
                        StackSection()
                        FootprintSection()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .onAppear { stop = m.watch() }
        .onDisappear { stop?(); stop = nil }
        // v2 drops a readied kill when the cursor moves
        .onChange(of: app.selected) { _, _ in m.armed = nil }
    }
}

@MainActor private func busy(_ app: AppModel, _ id: String, _ target: String) -> Bool {
    let s = app.runner.runOf(id, target)?.state
    return s == .sending || s == .landing
}

private struct Servers: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let m = app.state { Workstation(app: app) }
        let n = m.servers.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionHead(text: "serving · \(n)")
                Spacer()
                if n > 0 {
                    Lever(id: "machine.reap", word: m.armed == "reap" ? "again reaps · esc" : "reap orphaned", danger: m.armed == "reap")
                    Lever(id: "machine.killall", word: m.armed == "kill all" ? "again kills \(n) · esc" : "kill all", danger: true)
                }
            }
            .padding(.leading, 28).padding(.trailing, 16).padding(.bottom, 4)
            if n == 0 { Text("nothing serving").foregroundStyle(theme.inkFaint).padding(.leading, 28) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(m.servers, id: \.sid) { s in ServerRow(s: s) }
            }
            .paneRing("servers")
            mainLine(m).padding(.leading, 28).padding(.top, 8)
        }
    }

    @ViewBuilder private func mainLine(_ m: Workstation) -> some View {
        @Bindable var m = m
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let main = m.main {
                Text("main serves on :\(main.port)")
            } else if busy(app, "machine.main", "machine") {
                Text("starting main…").foregroundStyle(theme.inkDim)
            } else {
                Lever(id: "machine.main", word: "run main")
                Text("port")
                ModalTextField(MachinePage.portField, text: $m.mainPort)
                    .frame(width: 52)
                    .padding(.horizontal, 4)
                    .background(theme.vellumRaise)
                    .onChange(of: m.mainPort) { _, v in
                        let digits = v.filter(\.isNumber)
                        if digits != v { m.mainPort = digits }
                    }
                Text("\(app.registry.keyOf("machine.port")) edits").foregroundStyle(theme.inkFaint)
            }
        }
        .font(Theme.mono(12))
        .foregroundStyle(theme.inkFaint)
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let s: Server

    var body: some View {
        let m = app.state { Workstation(app: app) }
        let id = s.sid
        let h = HEALTH[s.health] ?? Health(word: s.health, dot: \.inkFaint, text: \.inkDim)
        let doing = busy(app, "machine.stop", id) ? "killing…" : busy(app, "machine.restart", id) ? "restarting…" : busy(app, "machine.swap", id) ? "swapping…" : ""
        let armed = m.armed == "kill \(id)"
        VStack(alignment: .leading, spacing: 0) {
            CursorRow(pane: "servers", key: RowKey.server(id)) { on in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        Dot(color: theme[keyPath: h.dot], breathe: h.breathe || !doing.isEmpty)
                        Text(s.label).font(Theme.display(17)).foregroundStyle(on ? theme.goldLeaf : theme.ink).lineLimit(1)
                        if !s.owned { Text("unmanaged").font(Theme.mono(11)).foregroundStyle(theme.ember) }
                        Spacer(minLength: 8)
                        Text(doing.isEmpty ? "\(h.word)\(s.latency.map { " · \(Int($0))ms" } ?? "")" : doing)
                            .font(Theme.mono(11)).foregroundStyle(doing.isEmpty ? theme[keyPath: h.text] : theme.inkDim)
                        Text(":\(s.port)").font(Theme.mono(11)).foregroundStyle(theme.inkFaint).frame(width: 52, alignment: .trailing)
                        Text(s.age).font(Theme.mono(11)).foregroundStyle(theme.inkFaint).frame(width: 52, alignment: .trailing)
                    }
                    .frame(minHeight: 36)
                    .padding(.leading, 28).padding(.trailing, 16)
                    .opacity(h.faded || !doing.isEmpty ? 0.6 : 1)
                    if s.error != nil || s.servesMismatch == true {
                        Text(s.servesMismatch == true ? "⚠ the port serves \(s.serves ?? "")" : s.error ?? "")
                            .font(Theme.mono(12)).foregroundStyle(theme.del).lineLimit(on ? nil : 1)
                            .padding(.leading, 48).padding(.trailing, 16)
                    }
                    if on { levers(m, id: id, armed: armed) }
                }
            }
            .overlay { if armed { Rectangle().stroke(theme.del.opacity(0.6), lineWidth: 1) } }
            if m.logFor == id { LogView(s: s) }
        }
    }

    /// The cursor row's facts and levers. What v2 kept in hover titles is spelled out here.
    private func levers(_ m: Workstation, id: String, armed: Bool) -> some View {
        let back = m.swapped[s.port]
        let swapWord = back.map { "⇄ back to \($0.label)" } ?? s.swapTo.map { "⇄ \($0)" } ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("⌂ \(MachineText.shortDir(s.dir))")
                if !s.owned, let pid = s.pid { Text("pid \(pid)") }
                if let b = s.behind, b != "0", !b.isEmpty { Text("\(b) behind main").foregroundStyle(theme.ember) }
                if let sv = s.serves, s.servesMismatch != true { Text("✓ \(sv.split(separator: " ").first.map(String.init) ?? sv)") }
                Spacer(minLength: 8)
                if s.url != nil { Lever(id: "machine.open", target: id, word: "open") }
                if s.owned {
                    Lever(id: m.logFor == id ? "machine.log.close" : "machine.log", target: id, word: "log")
                    Lever(id: "machine.restart", target: id, word: "restart")
                    if !swapWord.isEmpty { Lever(id: "machine.swap", target: id, word: swapWord) }
                }
                Lever(id: "machine.kill", target: id, word: armed ? "again kills it · esc" : "kill", danger: true)
            }
            Text(s.dir + (s.owned ? " · its own worktree; main's node_modules and .env; the one stack below"
                                  : " · a next-dev listener no preview session owns — task dev, or a leftover headless server"))
                .foregroundStyle(theme.inkFaint.opacity(0.8)).lineLimit(2)
            if let b = s.behind, b != "0", !b.isEmpty {
                Text("the checkout it serves trails origin/main — healthy means answering, not fresh").foregroundStyle(theme.inkFaint.opacity(0.8))
            }
        }
        .font(Theme.mono(12))
        .foregroundStyle(theme.inkFaint)
        .padding(.leading, 48).padding(.trailing, 16).padding(.bottom, 8)
    }
}

/// The open log as a pane: its lines are rows (C-w j to focus, j/k/G/gg to move). It follows new
/// output while the cursor isn't in it, or sits on its last line; moving up holds it still.
private struct LogView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let s: Server

    var body: some View {
        let m = app.state { Workstation(app: app) }
        let lines = m.logLines
        let focused = app.isFocused("log")
        let pinned = !focused || app.selected == lines.indices.last.map { "log:\($0)" }
        VStack(alignment: .leading, spacing: 4) {
            if s.jobs == true {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("web").foregroundStyle(m.logSrc == .web ? theme.ink : theme.inkFaint)
                    Text("jobs worker").foregroundStyle(m.logSrc == .jobs ? theme.ink : theme.inkFaint)
                    Lever(id: "machine.log.jobs", target: s.sid, word: "switch")
                }
                .font(Theme.mono(11))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if lines.isEmpty { Text("…").foregroundStyle(theme.inkDim) }
                        ForEach(lines.indices, id: \.self) { i in
                            let key = "log:\(i)"
                            let on = focused && app.selected == key
                            Text(lines[i].isEmpty ? " " : lines[i])
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(on ? theme.ink : theme.inkDim)
                                .background(on ? theme.goldWash : .clear)
                                .id(key)
                        }
                    }
                    .font(Theme.mono(11.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .onChange(of: lines.count, initial: true) { _, n in if pinned, n > 0 { proxy.scrollTo("log:\(n - 1)", anchor: .bottom) } }
                .onChange(of: focused ? app.selected : nil) { _, k in if let k { proxy.scrollTo(k) } }
            }
            .frame(height: 440)
            .background(theme.diffBg)
            .paneRing("log")
            if focused { Text("j/k move · G follows · h hides · C-w k back to the servers").font(Theme.mono(11)).foregroundStyle(theme.inkFaint) }
        }
        .padding(.leading, 48).padding(.trailing, 16).padding(.top, 4).padding(.bottom, 12)
    }
}

private struct StackSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let m = app.state { Workstation(app: app) }
        VStack(alignment: .leading, spacing: 4) {
            if let s = m.substrate {
                let starting = s.starting == true || busy(app, "machine.stack", "machine")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SectionHead(text: "stack")
                    Dot(color: !s.down ? theme.add : starting ? theme.ember : theme.del, breathe: s.down && starting)
                    Text("\(s.up)/\(s.total) up · from \(MachineText.shortDir(s.dir ?? s.project))").foregroundStyle(theme.inkDim)
                    Spacer()
                    if s.down {
                        if starting { Text("starting…").foregroundStyle(theme.ember) } else { Lever(id: "machine.stack", word: "start") }
                    }
                }
                Group {
                    Text("every server above reads and writes this one stack — swaps isolate code, never data").foregroundStyle(theme.inkFaint)
                    if s.home == false, let dir = s.dir {
                        Text("from \(MachineText.shortDir(dir)) — its own Postgres and ClickHouse, not main's").foregroundStyle(theme.ember)
                    }
                    if let broken = s.doctor?.broken, !broken.isEmpty {
                        Text(broken.map { "\($0.name) — \($0.detail)" }.joined(separator: " · ")).foregroundStyle(theme.del)
                    }
                    if s.db == "empty" {
                        Text("no app schema — every query fails until task dev:migrate").foregroundStyle(theme.del)
                    }
                    if let err = s.err { Text("compose up: \(err)").foregroundStyle(theme.del) }
                    if s.schema?.pg != nil {
                        let d = MachineText.drift(s.schema)
                        Text(d.isEmpty ? "schema in step with main" : "schema vs main: \(d)").foregroundStyle(d.isEmpty ? theme.inkFaint : theme.ember)
                        Text("applied heads — pg: \(s.schema?.pg?.head ?? "?") · ch: \(s.schema?.ch?.head ?? "?")").foregroundStyle(theme.inkFaint.opacity(0.8))
                    }
                    if !s.services.isEmpty {
                        FlowChips(items: s.services.map { x in
                            let tail = x.state == "done" ? " · done" : x.state == "failed" ? " · exited" : ""
                            return (MachineText.service(x.name, project: s.project) + tail, x.up ? 0 : x.state == "done" ? 1 : 2)
                        })
                        .padding(.top, 6)
                        // v2 kept each service's docker status in a hover title; the ones not up say it here
                        ForEach(s.services.filter { !$0.up }, id: \.name) { x in
                            Text("\(MachineText.service(x.name, project: s.project)): \(x.status)").foregroundStyle(theme.inkFaint)
                        }
                    }
                }
                .font(Theme.mono(12))
            } else {
                HStack { SectionHead(text: "stack"); Text("…").foregroundStyle(theme.inkFaint) }
            }
        }
        .font(Theme.mono(12))
        .padding(.leading, 28).padding(.trailing, 16)
    }
}

/// Service chips (0 up, 1 done, 2 down), wrapped to the width.
private struct FlowChips: View {
    @Environment(\.theme) private var theme
    let items: [(String, Int)]
    var body: some View {
        WrapLayout(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Text(it.0).font(Theme.mono(11))
                    .padding(.horizontal, 6)
                    .foregroundStyle(it.1 == 0 ? theme.inkDim : it.1 == 1 ? theme.inkFaint : theme.del)
                    .opacity(it.1 == 1 ? 0.7 : 1)

            }
        }
    }
}

/// Left-to-right, wrapping rows.
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

private struct FootprintSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let m = app.state { Workstation(app: app) }
        VStack(alignment: .leading, spacing: 6) {
            if let f = m.footprint {
                let mc = f.machine
                let used = mc.activeMb + mc.wiredMb + mc.compressedMb
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    SectionHead(text: "footprint")
                    Dot(color: mc.pressure == "ok" ? theme.add : mc.pressure == "high" ? theme.ember : theme.del, breathe: mc.pressure == "high")
                    Text("\(MachineText.gb(used))/\(MachineText.gb(mc.totalMb)) GB · \(mc.levelPct >= 0 ? "\(Int(mc.levelPct))% headroom" : "\(Int(mc.freeMb)) MB free") · swap \(MachineText.gb(mc.swap.usedMb))/\(MachineText.gb(mc.swap.totalMb)) GB")
                        .foregroundStyle(theme.inkDim)
                    Spacer()
                    if mc.pressure != "ok" {
                        Text(mc.pressure == "high" ? "pressure — dev may slow" : "critical — next dev dies here")
                            .foregroundStyle(mc.pressure == "high" ? theme.ember : theme.del)
                    }
                }
                MemoryBar(m: mc)
                Text("wired · active · compressed · inactive (reclaimable) · free").font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint.opacity(0.8))
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(mc.top.prefix(6).enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(p.rssMb >= 1024 ? "\(MachineText.gb(p.rssMb)) GB" : "\(Int(p.rssMb)) MB").foregroundStyle(theme.ink).frame(width: 64, alignment: .trailing)
                                Text(p.name).foregroundStyle(theme.inkDim).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int(p.cpu.rounded()))%").foregroundStyle(theme.inkFaint)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Facts(rows: repoFacts(f)).frame(maxWidth: .infinity, alignment: .leading)
                    Facts(rows: serverFacts(f)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            } else {
                SectionHead(text: "footprint · …")
            }
        }
        .font(Theme.mono(12))
        .padding(.leading, 28).padding(.trailing, 16)
    }

    private func repoFacts(_ f: Footprint) -> [(String, String)] {
        var out = [("\(f.repo.worktrees)", "worktrees"), ("\(f.repo.scratch)", "review scratch"), ("\(f.repo.nodeModulesClones)", "node_modules clones")]
        if let t = f.repo.disk.totalGb, t > 0 {
            out.append(("\(Int(f.repo.disk.pct ?? 0))%", "disk · \(Int(f.repo.disk.usedGb ?? 0))/\(Int(t)) GB"))
        }
        let hy = f.repo.hygiene.map { "hygiene \(MachineText.ago(max(60, (Date().timeIntervalSince1970 - $0.at).rounded(.down)))) ago · relinked \($0.stripped)" }
        out.append(("", hy ?? "hygiene not run yet"))
        return out
    }

    private func serverFacts(_ f: Footprint) -> [(String, String)] {
        let caches = f.server.caches.values.reduce(0, +)
        return [("\(Int(f.server.rssMb)) MB", "viewer · up \(MachineText.ago(f.server.uptimeS))"),
                ("\(f.server.threads)", "threads · \(f.server.children) child\(f.server.children == 1 ? "" : "ren")"),
                ("\(caches)", "cached answers"),
                ("", f.server.caches.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))]
    }
}

private struct Facts: View {
    @Environment(\.theme) private var theme
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).foregroundStyle(theme.ink).gridColumnAlignment(.trailing)
                    Text(r.1).foregroundStyle(r.0.isEmpty ? theme.inkFaint : theme.inkDim)
                }
            }
        }
    }
}

private struct MemoryBar: View {
    @Environment(\.theme) private var theme
    let m: Footprint.Machine
    var body: some View {
        GeometryReader { g in
            let w = { (mb: Double) in g.size.width * max(0, min(1, mb / max(1, m.totalMb))) }
            HStack(spacing: 0) {
                theme.inkDim.frame(width: w(m.wiredMb))
                theme.goldLeaf.frame(width: w(m.activeMb))
                theme.ember.frame(width: w(m.compressedMb))
                theme.rule.frame(width: w(m.inactiveMb))
                Spacer(minLength: 0)
            }
        }
        .frame(height: 5)
        .background(theme.vellumEdge)
    }
}
