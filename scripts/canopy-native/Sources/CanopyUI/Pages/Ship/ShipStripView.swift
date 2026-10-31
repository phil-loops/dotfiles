import CanopyCore
import SwiftUI

/// review/Ship.tsx: where the branch stands on its way to main, as one line under the title on
/// every tab, offering only the next step: run the gates (and why — the red ones), wait for them,
/// push (and the push as it happens) — or, diverged from origin, replace origin's copy inside the
/// force scope, its guards ✓/✗ beneath — or open the PR, and nothing once there's nothing to do.
/// Beside it ⟲ sync when the branch needs one, and under it the sync's steps while one runs — each
/// failing step with its reason in full, and the dirt decision inline. Every action shows its key.
public struct ShipStripView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String

    public init(branchID: String) { self.branchID = branchID }

    public var body: some View {
        let ship = ShipState.of(app)
        if let b = app.store.view(Branch.self, branchID) {
            let m = ship.motionOf(branchID)
            let shown = ship.gateShown.flatMap { $0.hasPrefix("\(branchID) ") ? String($0.dropFirst(branchID.count + 1)) : nil }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let progress = ship.progressOf(branchID)
                let rows = GatesRun.rows(progress, now: ctx.date.timeIntervalSince1970)
                VStack(alignment: .leading, spacing: 4) {
                    line(b, m, rows)
                    if let m { StepsStrip(branchID: branchID, motion: m) }
                    else if !rows.isEmpty, progress?.running == true || rows.contains(where: { $0.state == .red }) || shown != nil {
                        GatesStrip(branchID: branchID, rows: rows, progress: progress, shown: shown)
                    }
                    if m == nil, b.diverged, case .some(.some(let s)) = ship.forceScopeOf(app, branchID) { GuardStrip(guards: s.guards) }
                    if ship.inspecting == branchID { DivergenceView(branch: b) }
                    if app.keys.layer == .address, ship.addressing != nil { AddressSheet(branchID: branchID) }
                }
            }
            .font(Theme.text(11))
            .task(id: readKey(b, m)) { ship.readFacts(app, b, key: readKey(b, m)) }
            .task(id: "\(b.tip)|\(b.gates.rawValue)|\(shown ?? "")") { ship.readProgress(app, b, key: "\(b.tip)|\(b.gates.rawValue)|\(shown ?? "")", gate: shown) }
            .task(id: "\(b.diverged)|\(ShipState.scopeKey(b))") { if b.diverged { ship.readForceScope(app, branchID) } }
            .task(id: ship.inspecting) { if ship.inspecting == branchID { ship.readDivergence(app, b) } }
        }
    }

    /// dirt and the prep route are read per branch, re-read when the branch moves or a sync ends
    private func readKey(_ b: Branch, _ m: SyncMotion?) -> String {
        "\(b.repo)|\(b.name)|\(b.tip)|\(b.pushed.rawValue)|\(b.ahead)|\(b.behind)|\(b.drifted)|\(m?.phase.rawValue ?? "")"
    }

    @ViewBuilder private func line(_ b: Branch, _ m: SyncMotion?, _ rows: [GateRow]) -> some View {
        let ship = ShipState.of(app)
        let route = ReviewCommands.pushRoute(app, branchID)
        let push = latestPush()
        let live: Run.State? = push.flatMap { [.sending, .landing, .failed].contains($0.run.state) ? $0.run.state : nil }
        let forcing = route == "branch.force.arm" || route == "branch.force.confirm"
        let acts = route == "branch.gates.run" || route == "branch.push.arm" || route == "branch.push.confirm" || forcing
        let waiting = route == "branch.gates.wait"
        let running = rows.first { $0.state == .running }
        let red = rows.filter { $0.state == .red }
        let waived = rows.filter { $0.state == .waived }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let doing = m.flatMap({ $0.phase == .running ? $0.steps.first { $0.state == .run } : nil }) {
                Text("⟲ \(doing.label)…").foregroundStyle(theme.goldLeaf)
            } else if let said = said(b, m) {
                Text(said).foregroundStyle(m?.phase == .restacking ? theme.goldLeaf : theme.ember)
            } else {
                let needs = Syncing.needs(b, facts: ship.factsOf(branchID), prep: ship.prepOf(branchID))
                if !needs.isEmpty {
                    KeyButton(title: "⟲ sync", id: "review.sync", target: branchID)
                    Text(needs.joined(separator: " · ")).foregroundStyle(theme.inkFaint)
                }
            }
            if (acts || waiting) && live == nil {
                if let g = running {
                    Text("◌ \(g.name) \(GatesRun.secs(g.ms))").foregroundStyle(theme.goldLeaf)
                } else if !red.isEmpty {
                    Text("gates ✗").foregroundStyle(theme.ember)
                    ForEach(red, id: \.name) { g in Text(g.name).foregroundStyle(theme.ember) }
                    KeyButton(title: "skip", id: "review.gates.skip", target: branchID, quiet: true)
                } else if b.gates == .green && !waived.isEmpty {
                    Text("\(waived.count) skipped").foregroundStyle(theme.patina)
                }
            }
            if acts || live != nil {
                KeyButton(title: pushLabel(b, route: route, live: live, forced: push?.forced ?? false), id: "review.push", target: branchID,
                          gold: true, busy: live == .sending || live == .landing, failed: live == .failed)
            }
            if live == .failed, let err = push?.run.err { Text(err).foregroundStyle(theme.ember).lineLimit(2) }
            if live == nil, b.diverged, case .some(.some(let s)) = ship.forceScopeOf(app, branchID), !s.eligible,
               !s.guards.allSatisfy({ $0.ok || $0.k == "gates" }), let bad = s.guards.first(where: { !$0.ok }) {
                Text("diverged · ✗ \(bad.label)").foregroundStyle(theme.ember)
                Text("· sync carries it on top").foregroundStyle(theme.inkFaint)
            }
            if !acts && live == nil && app.store.view(Pr.self, branchID) == nil && app.forestModel.opensPR(branchID)
                && app.store.view(Warm.self, b.repo)?.prs == true {
                KeyButton(title: "open the PR ↗", id: "review.finish", target: branchID, gold: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// what the last sync left to say: a hand-off to Claude only until the tip moves
    private func said(_ b: Branch, _ m: SyncMotion?) -> String? {
        guard let m, m.phase != .running, m.phase != .done else { return nil }
        if (m.phase == .conflict || m.phase == .claude) && b.tip != m.tip { return nil }
        return m.phase.word
    }

    /// the latest push or force this launch
    private func latestPush() -> (run: Run, forced: Bool)? {
        let p = app.runner.runOf("branch.push.confirm", branchID)
        let f = app.runner.runOf("branch.force.confirm", branchID)
        if let f, p == nil || f.t0 > p!.t0 { return (f, true) }
        return p.map { ($0, false) }
    }

    private func pushLabel(_ b: Branch, route: String?, live: Run.State?, forced: Bool) -> String {
        switch live {
        case .sending: return forced ? "replacing origin…" : "pushing…"
        case .landing: return forced ? "✓ replaced" : "✓ pushed"
        case .failed: return forced ? "retry the force" : "retry the push"
        default: break
        }
        switch route {
        case "branch.gates.run": return b.gates == .red ? "re-run the gates" : "run the gates"
        case "branch.force.confirm":
            let lease: String = {
                if case .some(.some(let s)) = ShipState.of(app).forceScopeOf(app, branchID) { return String(s.lease.prefix(7)) }
                return ""
            }()
            return "\(app.registry.keyOf("review.push")) again · force-with-lease over origin's \(lease)"
        case "branch.force.arm": return "diverged · replace origin?"
        case "branch.push.confirm": return "\(app.registry.keyOf("review.push")) again to push"
        default: return "push \(b.pushed == .local ? b.commits : b.ahead)"
        }
    }
}

/// A button that is a command: it shows the command's key (from the registry, so keys.toml moves
/// it), dispatches by id, and is never the only way in — the key is.
struct KeyButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let title: String
    let id: String
    var target: String?
    var arg: Any?
    var gold = false
    var busy = false
    var failed = false
    /// show the command's `:` name instead of a key when it has none
    var quiet = false

    var body: some View {
        let keys = app.registry.command(id)?.keys ?? []
        Button { app.runner.dispatch(id, via: .click, target: target, arg: arg) } label: {
            HStack(spacing: 5) {
                Text(title)
                if !busy {
                    Text(keys.first.map(glyph) ?? (quiet ? ":\(id)" : ""))
                        .font(Theme.text(10.5)).foregroundStyle(theme.inkFaint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(failed ? theme.ember : gold ? theme.goldLeaf : theme.ink)
            .background(RoundedRectangle(cornerRadius: 4).fill(failed ? theme.emberWash : gold ? theme.goldWash.opacity(2) : theme.vellumRaise))
            .opacity(busy ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

private let stepIcon: [StepState: String] = [.ok: "✓", .fail: "✗", .run: "⟳", .skip: "↷", .idle: "·"]

private func stepColor(_ s: StepState, _ theme: Theme) -> Color {
    switch s {
    case .ok: theme.patina
    case .fail: theme.ember
    case .run: theme.goldLeaf
    case .skip, .idle: theme.inkFaint
    }
}

/// The sync's steps: every one visible, a failing step's reason in full, the dirt decision inline.
struct StepsStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String
    let motion: SyncMotion

    var body: some View {
        let ship = ShipState.of(app)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                ForEach(motion.steps, id: \.id) { s in
                    Text("\(stepIcon[s.state] ?? "·") \(s.label)").foregroundStyle(stepColor(s.state, theme))
                }
                Spacer(minLength: 0)
                if motion.phase != .running && motion.phase != .dirt { KeyButton(title: "put away", id: "review.sync.dismiss", target: branchID, quiet: true) }
            }
            ForEach(motion.steps.filter { $0.note != nil }, id: \.id) { s in
                (Text(s.label).bold() + Text(" \(s.note ?? "")")).foregroundStyle(s.state == .fail ? theme.ember : theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if motion.phase == .dirt, let dirt = motion.dirt {
                let open = ship.dirtOpen.flatMap { $0.hasPrefix("\(branchID)|") ? String($0.dropFirst(branchID.count + 1)) : nil }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(dirt.files, id: \.self) { f in
                        Text("\(f == open ? "▾" : "▸") \(f)").foregroundStyle(f == open ? theme.goldLeaf : theme.ink)
                    }
                    if let row = dirt.rows.first(where: { $0.path == open }) { DirtDiff(row: row) }
                    HStack(spacing: 8) {
                        KeyButton(title: "fold into the commit", id: "review.sync.fold", target: branchID, gold: true, quiet: true)
                        KeyButton(title: "stash & continue", id: "review.sync.stash", target: branchID, quiet: true)
                        KeyButton(title: "stop", id: "review.sync.stop", target: branchID, quiet: true)
                        KeyButton(title: "show the next file's change", id: "review.sync.dirt.show", target: branchID, quiet: true)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(6)
        .overlay(Rectangle().stroke(theme.rule, lineWidth: 1))
    }
}

/// One dirty file's uncommitted change, read-only — what fold or stash would act on.
struct DirtDiff: View {
    @Environment(\.theme) private var theme
    let row: DirtRow
    var body: some View {
        let lines = row.patch.components(separatedBy: "\n").filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    let add = l.hasPrefix("+") && !l.hasPrefix("+++"), del = l.hasPrefix("-") && !l.hasPrefix("---")
                    Text(l.isEmpty ? " " : l).font(Theme.text(11.5))
                        .foregroundStyle(add ? theme.add : del ? theme.del : l.hasPrefix("@@") ? theme.inkFaint : theme.diffInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(add ? theme.addBg : del ? theme.delBg : .clear)
                }
            }
        }
        .frame(maxHeight: 240)
        .background(theme.diffBg)
    }
}

/// Every gate of the run as a step with its time, and the output of the one running (or the one
/// `, g` picked) — read from the run's journal on the server, so a relaunch picks it up mid-run.
struct GatesStrip: View {
    @Environment(\.theme) private var theme
    let branchID: String
    let rows: [GateRow]
    let progress: GateProgress?
    let shown: String?

    static let step: [GateRow.State: StepState] = [.queued: .idle, .running: .run, .green: .ok, .waived: .skip, .red: .fail, .stopped: .fail]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("gates").foregroundStyle(theme.inkFaint)
                ForEach(rows, id: \.name) { g in
                    let s = Self.step[g.state] ?? .idle
                    HStack(spacing: 3) {
                        Text("\(stepIcon[s] ?? "·") \(g.name)").foregroundStyle(stepColor(s, theme))
                        if g.ms != nil { Text(GatesRun.secs(g.ms)).foregroundStyle(theme.inkFaint) }
                    }
                    .underline(progress?.tail?.gate == g.name)
                }
                Spacer(minLength: 0)
                if progress?.running == true, let e = progress?.elapsed { Text("\(GatesRun.secs(e * 1000)) in").foregroundStyle(theme.inkFaint) }
                KeyButton(title: "output", id: "review.gates.show", target: branchID)
            }
            ForEach(rows.filter { $0.state == .red && $0.summary != nil && $0.name != progress?.tail?.gate }, id: \.name) { g in
                (Text(g.name).bold() + Text(" \(g.summary ?? "")")).foregroundStyle(theme.ember)
            }
            if let t = progress?.tail {
                Text("\(t.gate) · \(rows.first { $0.name == t.gate }?.state == .running ? "output so far" : "output")")
                    .font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(t.lines.isEmpty ? "(no output yet)" : t.lines.joined(separator: "\n"))
                            .font(Theme.text(11)).foregroundStyle(theme.diffInk).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxHeight: 200)
                    .background(theme.diffBg)
                    .onChange(of: t.lines.count, initial: true) { _, _ in proxy.scrollTo("end") }
                }
            }
        }
        .padding(6)
        .overlay(Rectangle().stroke(theme.rule, lineWidth: 1))
    }
}

/// The force scope's guards: each ✓ or ✗, so a refusal reads as the guard that failed.
struct GuardStrip: View {
    @Environment(\.theme) private var theme
    let guards: [ForceScope.Guard]
    var body: some View {
        HStack(spacing: 12) {
            Text("replace origin").foregroundStyle(theme.inkFaint)
            ForEach(guards, id: \.k) { g in Text("\(g.ok ? "✓" : "✗") \(g.label)").foregroundStyle(g.ok ? theme.patina : theme.ember) }
            Spacer(minLength: 0)
        }
        .padding(6)
        .overlay(Rectangle().stroke(theme.rule, lineWidth: 1))
    }
}

/// What a divergence is: each side's commits (twins marked), whether local contains origin, the PR before and after a push.
struct DivergenceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branch: Branch

    var body: some View {
        let d = ShipState.of(app).divergence[branch.id]
        VStack(alignment: .leading, spacing: 3) {
            switch d {
            case .none: Text("…").foregroundStyle(theme.inkFaint)
            case .some(.none): Text("couldn't read the divergence").foregroundStyle(theme.ember)
            case .some(.some(let d)):
                (Text("vs \(d.upstream)").bold() + Text(" \(DivergedDetail.containmentWord[d.containment] ?? d.containment)\(d.overlap.isEmpty ? "" : " — \(d.overlap.joined(separator: ", "))")"))
                Text("only here").bold()
                ForEach(Array(d.ahead.enumerated()), id: \.offset) { _, c in
                    Text("\(c.sha) \(c.subject)\(c.matched ? " · twin on origin" : c.fromMain ? " · main's" : "")")
                        .foregroundStyle(c.matched || c.fromMain ? theme.inkFaint : theme.ink)
                }
                Text("only on origin").bold()
                ForEach(Array(d.behind.enumerated()), id: \.offset) { _, c in
                    Text("\(c.sha) \(c.subject)\(c.matched ? " · twin here" : "")").foregroundStyle(c.matched ? theme.inkFaint : theme.ink)
                }
                (Text("the PR").bold() + Text(" now \(d.prNow.isEmpty ? "empty" : d.prNow) · after a push \(d.prAfter.isEmpty ? "empty" : d.prAfter)"))
            }
        }
        .foregroundStyle(theme.inkDim)
        .padding(6)
        .overlay(Rectangle().stroke(theme.rule, lineWidth: 1))
    }
}

/// `E` on a thread: who writes its fix. Claude (a fresh session in the branch's worktree, the
/// prompt drafted unsent), you in Helix, or — once a commit exists — pick it, which writes the
/// commit's `Addresses:` trailer. Its keys are its own layer's: ↵ or c, o, p, 1–9, esc.
struct AddressSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String

    var body: some View {
        let ship = ShipState.of(app)
        let t = ship.addressing.flatMap { app.store.view(CanopyCore.Thread.self, $0) }
        VStack(alignment: .leading, spacing: 4) {
            (Text("Address it").foregroundStyle(theme.goldLeaf)
                + Text(" · \(t?.comments.first?.author ?? "") on \(t.map { shipLeaf($0.path) } ?? "")").foregroundStyle(theme.inkFaint))
            Text(Markdown.plain(t?.comments.first?.body ?? "", max: 160)).foregroundStyle(theme.inkDim)
            if !ship.addressPicking {
                row(app.registry.command("review.address.claude")?.keys.map(glyph).joined(separator: " ") ?? "↵", "claude")
                row(app.registry.keyOf("review.address.helix"), "helix")
                row(app.registry.keyOf("review.address.pick.list"), "pick its commit")
            } else if WordsState.of(app).shown[branchID] == nil {
                Text("reading the commits…").foregroundStyle(theme.inkFaint)
            } else {
                let c = ReviewCommands.addressCandidates(app)
                if c.isEmpty { Text("no unpushed commits").foregroundStyle(theme.inkFaint) }
                ForEach(Array(c.enumerated()), id: \.offset) { i, x in row("\(i + 1)", "\(x.short.prefix(7)) \(x.subject)") }
            }
            Text("esc closes").font(Theme.text(10.5)).foregroundStyle(theme.inkFaint)
        }
        .padding(8)
        .background(theme.vellumRaise)
        .overlay(Rectangle().stroke(theme.goldDeep, lineWidth: 1))
    }

    private func row(_ key: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(key).foregroundStyle(theme.goldLeaf).frame(minWidth: 28, alignment: .leading)
            Text(what).foregroundStyle(theme.ink)
        }
    }
}
