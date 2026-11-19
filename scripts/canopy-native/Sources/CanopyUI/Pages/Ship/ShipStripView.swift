import CanopyCore
import SwiftUI

/// Persistent shipping controls with the branch's next action, unavailable reason and live steps.
public struct ShipStripView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduced
    let branchID: String
    let sidebar: Bool

    public init(branchID: String, sidebar: Bool = false) { self.branchID = branchID; self.sidebar = sidebar }

    public var body: some View {
        let ship = ShipState.of(app)
        if let b = app.store.view(Branch.self, branchID) {
            let m = ship.motionOf(branchID)
            let shown = ship.gateShown.flatMap { $0.hasPrefix("\(branchID) ") ? String($0.dropFirst(branchID.count + 1)) : nil }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let progress = ship.progressOf(branchID)
                let rows = GatesRun.rows(progress, now: ctx.date.timeIntervalSince1970)
                let previous = ship.previousOf(branchID)
                let before = GatesRun.previousRows(current: progress, previous: previous,
                                                   inFlight: b.gates == .running || GatesRun.isRunning(progress), now: ctx.date.timeIntervalSince1970)
                let forceNext = ["branch.force.arm", "branch.force.confirm"].contains(ReviewCommands.pushRoute(app, branchID))
                let guards: ForceScope? = { if m == nil, b.diverged, forceNext, case .some(.some(let s)) = ship.forceScopeOf(app, branchID) { return s }; return nil }()
                let slot = ShipSlot.pick(facts(b, m, rows, progress, shown, before, guards: guards != nil, ship))
                VStack(alignment: .leading, spacing: 4) {
                    line(b, m, rows, progress, now: ctx.date.timeIntervalSince1970, slot: slot)
                    switch slot {
                    case .motion: if let m { StepsStrip(branchID: branchID, motion: m, vertical: sidebar) }
                    case .gates: GatesStrip(branchID: branchID, rows: rows, progress: progress, shown: shown, vertical: sidebar)
                    // the left tree's checks while the new tree's run readies: history, dimmed and said so
                    case .previousGates: GatesStrip(branchID: branchID, rows: before, progress: previous, shown: nil, vertical: sidebar, previous: true)
                    case .guards: if let guards { GuardStrip(guards: guards.guards, vertical: sidebar) }
                    case .none: EmptyView()
                    }
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

    private func facts(_ b: Branch, _ m: SyncMotion?, _ rows: [GateRow], _ progress: GateProgress?, _ shown: String?, _ before: [GateRow],
                       guards: Bool, _ ship: ShipState) -> ShipSlot.Facts {
        let gates = !rows.isEmpty && !ship.gatesHidden.contains(branchID)
        return ShipSlot.Facts(
            motion: m?.phase,
            gatesAsked: gates && shown != nil,
            gatesFailed: gates && rows.contains { $0.state == .red || $0.state == .stopped },
            gatesRunning: gates && GatesRun.isRunning(progress) || sidebar && b.gates == .running && before.isEmpty,
            guards: guards,
            previousGates: !before.isEmpty && !ship.gatesHidden.contains(branchID))
    }

    /// dirt and the prep route are read per branch, re-read when the branch moves or a sync ends
    private func readKey(_ b: Branch, _ m: SyncMotion?) -> String { ShipState.factsKey(b, m) }

    @ViewBuilder private func line(_ b: Branch, _ m: SyncMotion?, _ rows: [GateRow], _ progress: GateProgress?, now: Double, slot: ShipSlot) -> some View {
        let detailed = slot == .gates
        let ship = ShipState.of(app)
        let route = ReviewCommands.pushRoute(app, branchID)
        let push = latestPush()
        // a failed push explains the button only while pushing is still the next step; the route owns the label
        let pushing = [nil, "branch.push.arm", "branch.push.confirm", "branch.force.arm", "branch.force.confirm"].contains(route)
        let live: Run.State? = push.flatMap { [.sending, .landing].contains($0.run.state) || $0.run.state == .failed && pushing ? $0.run.state : nil }
        let stepping = route.flatMap { ["branch.conform", "branch.catchup"].contains($0) ? app.runner.runOf($0, branchID) : nil }
            .map { [.sending, .landing].contains($0.state) } == true
        let forcing = route == "branch.force.arm" || route == "branch.force.confirm"
        let acts = route == "branch.gates.run" || route == "branch.gates.quick" || route == "branch.push.arm" || route == "branch.push.confirm"
            || route == "branch.catchup" || route == "branch.conform" || forcing
        // a run in flight that `p` can't move up still owns the line: its setup step, never "push unavailable"
        let waiting = route == "branch.gates.next" || route == nil && b.gates == .running
        let control = ShipControlState.push(route: route, situation: app.forestModel.branchView(branchID).map { ShipRules.says($0.st, $0.b, $0.pr) })
        let running = rows.first { $0.state == .running }
        let red = rows.filter { $0.state == .red }
        let waived = rows.filter { $0.state == .waived }
        let syncButton = KeyButton(title: "⟲ sync", id: "review.sync", target: branchID, busy: m?.phase == .running)
            .disabled(b.tip.isEmpty || m?.phase == .dirt || m == nil && ship.syncNeeds(b)?.isEmpty == true)
            .explains("ship|sync", "sync: the branch is behind its parent or main, or has dirt — it rebases and tidies")
        let label = stepping ? (route == "branch.conform" ? "taking origin's copy…" : "catching up…")
            : acts || waiting || live != nil ? pushLabel(b, route: route, live: live, forced: push?.forced ?? false) : "push"
        let pushButton = KeyButton(title: label, id: "review.push", target: branchID,
                                   gold: control.enabled, busy: stepping || live == .sending || live == .landing, failed: live == .failed)
            .disabled(!control.enabled)
            .settles(label, reduced: reduced)
            .explains("ship|push", "p: this branch's next step — run the gates, then push to origin")
        let layout = sidebar ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        layout {
            if sidebar {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { pushButton; syncButton }.fixedSize()
                    VStack(alignment: .leading, spacing: 6) { pushButton; syncButton }
                }
            } else { syncButton }
            if slot != .motion, let doing = m.flatMap({ $0.phase == .running ? $0.steps.first { $0.state == .run } : nil }) {
                Text("\(doing.label)…").foregroundStyle(theme.goldLeaf)
            } else if m == nil {
                // the last answer stays while the branch's new one is read, dimmed: it describes
                // a tree the branch has left (A5)
                let last = ship.lastReads(branchID)
                let needs = Syncing.needs(b, facts: last.facts, prep: last.prep)
                if !needs.isEmpty {
                    Text(needs.joined(separator: " · ") + (last.stale ? " …" : "")).foregroundStyle(theme.inkFaint)
                        .opacity(last.stale ? 0.5 : 1)
                        .explains("ship|needs", last.stale ? "read for the branch before it moved — re-reading" : "what this branch needs before it can push")
                }
            }
            if (acts || waiting) && live == nil && !sidebar {
                if let g = running {
                    // the strip beneath names the running step and its time; the line then says only the stage
                    let stuck = GatesRun.stuck(rows) != nil
                    Text(detailed ? (stuck ? "◌ gates · stuck?" : "◌ gates") : "◌ \(g.name) \(GatesRun.secs(g.ms))\(stuck ? " · stuck?" : "")")
                        .foregroundStyle(stuck ? theme.ember : theme.goldLeaf)
                        .explains("ship|gates", "the push gates are running on this tree; p pushes once every one is green")
                } else if let w = GatesRun.waiting(progress, rows: rows, inFlight: b.gates == .running || GatesRun.isRunning(progress), now: now) {
                    Text("◌ \(w.text)\(w.secs.map { " · " + GatesRun.secs($0 * 1000) } ?? "")").foregroundStyle(w.stuck ? theme.ember : theme.goldLeaf)
                        .explains("ship|gates", w.stuck ? "the gates haven't moved in a while: , g shows what the run is doing" : "the gates are between steps: readying the checkout, or waiting for a slot")
                } else if !red.isEmpty {
                    Text("gates ✗").foregroundStyle(theme.ember)
                        .explains("ship|gates", "a gate failed on this tree: , g shows its output, skip waives it for this code")
                    // the strip beneath lists them when it shows; the line names them only when it doesn't
                    if !detailed { ForEach(red, id: \.name) { g in Text(g.name).foregroundStyle(theme.ember) } }
                    KeyButton(title: "skip", id: "review.gates.skip", target: branchID)
                } else if rows.contains(where: { $0.state == .stopped }) {
                    Text("gates stopped").foregroundStyle(theme.inkDim)
                } else if b.gates == .green && !waived.isEmpty {
                    let quick = GatesRun.quick(rows)
                    let others = waived.count - quick.count
                    if !quick.isEmpty {
                        Text("quick · CI checks \(quick.joined(separator: ", "))").foregroundStyle(theme.goldLeaf)
                            .explains("ship|gates", "green on the quick gates: typecheck and lint didn't run here — CI runs them on the push")
                    }
                    if others > 0 { Text("\(others) skipped").foregroundStyle(theme.patina) }
                }
            }
            if !sidebar { pushButton }
            if sidebar && !red.isEmpty { KeyButton(title: "skip failed gates", id: "review.gates.skip", target: branchID) }
            if live != .sending && live != .landing, let reason = control.reason, !waiting {
                Text(reason).foregroundStyle(theme.inkFaint)
            }
            if live == nil && app.store.view(Pr.self, branchID) != nil
                && (route == "branch.gates.run" || route == "branch.push.arm" && b.gates != .green && b.gates != .running) {
                KeyButton(title: "quick", id: "review.gates.quick", target: branchID)
                    .explains("ship|gates", "a follow-up onto an open PR: env, fresh, format and tests here — typecheck and lint left to CI, which runs them on the push")
            }
            if live == .failed, let err = push?.run.err { Text(err).foregroundStyle(theme.ember).lineLimit(2) }
            if live == nil, let said = b.pushSaid { Text(said).foregroundStyle(said.hasPrefix("pushed") ? theme.inkFaint : theme.ember).lineLimit(2) }
            if live == nil, slot != .guards, b.diverged, case .some(.some(let s)) = ship.forceScopeOf(app, branchID), !s.eligible,
               !s.guards.allSatisfy({ $0.ok || $0.k == "gates" }), let bad = s.guards.first(where: { !$0.ok }) {
                Text("diverged · ✗ \(bad.label)").foregroundStyle(theme.ember)
                Text("· sync catches it up here · then \(app.registry.keyOf("review.push")) pushes").foregroundStyle(theme.inkFaint)
            }
            if !acts && live == nil && app.store.view(Pr.self, branchID) == nil && app.forestModel.opensPR(branchID)
                && app.store.view(Warm.self, b.repo)?.prs == true {
                KeyButton(title: "open the PR ↗", id: "review.finish", target: branchID, gold: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// what the last sync left to say: a hand-off to Claude only until the tip moves
    /// the latest push or force this launch
    private func latestPush() -> (run: Run, forced: Bool)? {
        let p = app.runner.runOf("branch.push.confirm", branchID)
        let f = app.runner.runOf("branch.force.confirm", branchID)
        if let f, p == nil || f.t0 > p!.t0 { return (f, true) }
        return p.map { ($0, false) }
    }

    /// What the gates say about a push they only advise on (P5): the reds by name, never a bare badge.
    private func gatesAdvice(_ b: Branch) -> String {
        if b.gates == .running { return "gates running" }
        let reds = GatesRun.rows(ShipState.of(app).progressOf(branchID), now: Date().timeIntervalSince1970)
            .filter { $0.state == .red }.map(\.name)
        if !reds.isEmpty { return "gates ✗ \(reds.joined(separator: ", "))" }
        return b.gates == .red ? "gates ✗" : "gates not run"
    }

    private func pushLabel(_ b: Branch, route: String?, live: Run.State?, forced: Bool) -> String {
        switch live {
        case .sending: return forced ? "replacing origin…" : "pushing…"
        case .landing: return forced ? "✓ replaced" : "✓ pushed"
        case .failed: return forced ? "retry the force" : "retry the push"
        default: break
        }
        switch route {
        case "branch.gates.next": return "prioritize gates"
        case "branch.catchup": return "catch up to \(b.owes.map(shipLeaf) ?? shipLeaf(b.parent)) first"
        case "branch.conform": return "take origin's copy"
        case "branch.gates.run": return b.gates == .red ? "re-run the gates" : "run the gates"
        case "branch.gates.quick": return b.gates == .red ? "re-run the quick gates" : "run the quick gates"
        case "branch.force.confirm":
            let lease: String = {
                if case .some(.some(let s)) = ShipState.of(app).forceScopeOf(app, branchID) { return String(s.lease.prefix(7)) }
                return ""
            }()
            return "\(app.registry.keyOf("review.push")) again · force-with-lease over origin's \(lease)"
        case "branch.force.arm": return "diverged · replace origin?"
        case "branch.push.queue": return "push when the gates go green"
        case "branch.push.early.arm": return "queued — pushes when green · \(app.registry.keyOf("review.push")) ships it now?"
        case "branch.push.early": return "\(app.registry.keyOf("review.push")) again · ships this code without the gates — the door says it was your call"
        case "branch.push.confirm":
            // the second press says what the push carries when its gates only advise (P5)
            let again = "\(app.registry.keyOf("review.push")) again to push"
            return b.gates == .green ? again : "\(again) · \(gatesAdvice(b)) — CI checks it"
        default:
            let n = "push \(b.pushed == .local ? b.commits : b.ahead)"
            return b.gates == .green || route != "branch.push.arm" ? n : "\(n) · \(gatesAdvice(b))"
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

    var body: some View {
        let keys = app.registry.command(id)?.keys ?? []
        Button { app.runner.dispatch(id, via: .click, target: target, arg: arg) } label: {
            HStack(spacing: 5) {
                Text(title)
                if !busy {
                    // a command with no key shows no hint: the title is the verb, and : reaches it by name
                    Text(keys.first.map(glyph) ?? "")
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
    var vertical = false

    var body: some View {
        let ship = ShipState.of(app)
        VStack(alignment: .leading, spacing: 3) {
            let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                ForEach(motion.steps, id: \.id) { s in
                    let shown = s.id == .gates ? Syncing.gatesShown(s.state, live: app.store.view(Branch.self, branchID)?.gates ?? .none) : s.state
                    Text("\(stepIcon[shown] ?? "·") \(s.label)").foregroundStyle(stepColor(shown, theme))
                }
                if !vertical { Spacer(minLength: 0) }
                if !vertical && motion.phase != .running && motion.phase != .dirt { KeyButton(title: "put away", id: "review.sync.dismiss", target: branchID) }
            }
            ForEach(motion.steps.filter { $0.note != nil }, id: \.id) { s in
                (Text(s.label).bold() + Text(" \(s.note ?? "")")).foregroundStyle(s.state == .fail ? theme.ember : theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if vertical && motion.phase != .running && motion.phase != .dirt {
                KeyButton(title: "put away", id: "review.sync.dismiss", target: branchID).padding(.top, 4)
            }
            if motion.phase == .dirt, let dirt = motion.dirt {
                let open = ship.dirtOpen.flatMap { $0.hasPrefix("\(branchID)|") ? String($0.dropFirst(branchID.count + 1)) : nil }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(dirt.files, id: \.self) { f in
                        Text("\(f == open ? "▾" : "▸") \(f)").foregroundStyle(f == open ? theme.goldLeaf : theme.ink)
                    }
                    if let row = dirt.rows.first(where: { $0.path == open }) { DirtDiff(row: row) }
                    HStack(spacing: 8) {
                        KeyButton(title: "fold into the commit", id: "review.sync.fold", target: branchID, gold: true)
                        KeyButton(title: "stash & continue", id: "review.sync.stash", target: branchID)
                        KeyButton(title: "stop", id: "review.sync.stop", target: branchID)
                        KeyButton(title: "show the next file's change", id: "review.sync.dirt.show", target: branchID)
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
    var vertical = false
    /// the rows are a run for a tree the branch has left: the previous commit's checks, not this code's
    var previous = false

    static let step: [GateRow.State: StepState] = [.queued: .idle, .running: .run, .green: .ok, .waived: .skip, .red: .fail, .stopped: .idle, .skipped: .skip]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if vertical {
                HStack {
                    Text(previous ? Self.previousLabel : "checks").foregroundStyle(theme.inkFaint)
                    Spacer(minLength: 0)
                    if !previous, GatesRun.isRunning(progress), let elapsed = progress?.elapsed {
                        Text(GatesRun.secs(elapsed * 1000)).foregroundStyle(theme.inkFaint).monospacedDigit()
                    }
                    KeyButton(title: "output", id: "review.gates.show", target: branchID)
                }
                .padding(.bottom, 5)
                ForEach(rows, id: \.name) { gate in
                    let step = Self.step[gate.state] ?? .idle
                    HStack(spacing: 6) {
                        Text(stepIcon[step] ?? "·").foregroundStyle(stepColor(step, theme)).frame(width: 12)
                        Text(gate.label).foregroundStyle(stepColor(step, theme))
                        Spacer(minLength: 0)
                        if let ms = gate.ms { Text(GatesRun.secs(ms)).foregroundStyle(theme.inkFaint).monospacedDigit() }
                    }
                    .padding(.vertical, 2)
                    .help(gate.summary ?? gate.label)
                    if let quiet = gate.quiet, quiet > GatesRun.stuckAfter {
                        Text("no output for \(GatesRun.secs(quiet * 1000)) — stuck?").foregroundStyle(theme.ember)
                    }
                }
                let quick = GatesRun.quick(rows)
                if !quick.isEmpty {
                    Text("quick gates · CI checks \(quick.joined(separator: ", "))").foregroundStyle(theme.goldLeaf)
                }
                if rows.isEmpty, let waiting = GatesRun.waiting(progress, rows: rows, inFlight: true, now: Date().timeIntervalSince1970) {
                    Text(waiting.text).foregroundStyle(waiting.stuck ? theme.ember : theme.inkDim)
                }
            } else {
                HStack(spacing: 12) {
                    Text(previous ? Self.previousLabel : "gates").foregroundStyle(theme.inkFaint)
                    ViewThatFits(in: .horizontal) {
                        gateRow(timings: true)
                        gateRow(timings: false)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        if GatesRun.isRunning(progress), let e = progress?.elapsed { Text("\(GatesRun.secs(e * 1000)) in").foregroundStyle(theme.inkFaint) }
                        KeyButton(title: "output", id: "review.gates.show", target: branchID)
                    }
                    .fixedSize()
                    .layoutPriority(1)
                }
            }
            if let note = progress?.events?.last(where: { $0.event == "result" })?.note, !note.isEmpty {
                Text(note).foregroundStyle(theme.inkDim)
            }
            ForEach(rows.filter { $0.state == .red && $0.summary != nil && $0.name != progress?.tail?.gate }, id: \.name) { g in
                (Text(g.name).bold() + Text(" \(g.summary ?? "")")).foregroundStyle(theme.ember)
            }
            if let t = progress?.tail {
                let red = rows.first { $0.name == t.gate }?.state == .red
                if GatesRun.fullOutput(t.gate, rows: rows, shown: shown) {
                    // the strip already names the gate (underlined): the caption says only what this is
                    Text(red ? "output" : "output so far").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                    ScrollViewReader { proxy in
                        ScrollView {
                            // colour means outcome: a failing gate's lines in ember, everything else plain ink
                            Text(t.lines.isEmpty ? "(no output yet)" : t.lines.joined(separator: "\n"))
                                .font(Theme.text(11)).foregroundStyle(red ? theme.ember : theme.inkDim).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxHeight: 200)
                        .background(theme.diffBg)
                        .onChange(of: t.lines.count, initial: true) { _, _ in proxy.scrollTo("end") }
                    }
                } else {
                    // a passing or running gate's output is a count until asked for
                    Text("\(t.lines.count) line\(t.lines.count == 1 ? "" : "s") so far").font(Theme.text(11)).foregroundStyle(theme.inkFaint)
                }
            }
        }
        .padding(vertical ? 0 : 6)
        .overlay(Rectangle().stroke(vertical ? .clear : theme.rule, lineWidth: 1))
        .opacity(previous ? 0.5 : 1)
    }

    static let previousLabel = "previous commit · re-running for this one"

    @ViewBuilder private func gateRow(timings: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(rows, id: \.name) { g in
                let s = Self.step[g.state] ?? .idle
                HStack(spacing: 3) {
                    Text("\(stepIcon[s] ?? "·") \(g.name)\(g.state == .skipped ? " skipped" : g.state == .stopped ? " stopped" : "")").foregroundStyle(stepColor(s, theme))
                    if timings, g.ms != nil { Text(GatesRun.secs(g.ms)).foregroundStyle(theme.inkFaint) }
                    if let q = g.quiet, q > GatesRun.stuckAfter {
                        Text("· no output for \(GatesRun.secs(q * 1000)) — stuck?").foregroundStyle(theme.ember)
                            .explains("ship|gates|stuck", "the gate holds its slot but has written nothing for a while: , g shows its last lines; the machine page kills the run")
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .underline(progress?.tail?.gate == g.name)
            }
        }
    }
}

/// The force scope's guards: each ✓ or ✗, so a refusal reads as the guard that failed.
struct GuardStrip: View {
    @Environment(\.theme) private var theme
    let guards: [ForceScope.Guard]
    var vertical = false
    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Text("replace origin").foregroundStyle(theme.inkFaint)
            ForEach(guards, id: \.k) { g in Text("\(g.ok ? "✓" : "✗") \(g.label)").foregroundStyle(g.ok ? theme.patina : theme.ember) }
            if !vertical { Spacer(minLength: 0) }
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
