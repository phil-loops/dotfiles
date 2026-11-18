import CanopyCore
import Foundation

// gates.ts: a gates run as the push screen shows it — each gate queued, running (and for how
// long), green or red — from the run's own event journal (GET /gates-progress), so a run that died
// without a result says so instead of looking like one still going. Pure.

/// One line of the run's journal. `gates` is a plan's names or a result's verdicts.
public struct GateEvent: Decodable, Equatable, Sendable {
    public struct Verdict: Decodable, Equatable, Sendable {
        public var name: String
        public var ok: Bool?
        public var ms: Double?
        public var summary: String?
        public var warn: String?
        public var skipped: Bool?
        public var advisory: Bool?
    }

    public var event: String
    public var gate: String?
    /// a plan's names
    public var planned: [String]?
    /// a result's per-gate verdicts
    public var verdicts: [Verdict]?
    public var ok: Bool?
    public var ms: Double?
    public var ts: Double?
    /// a waived gate: green by decision, not by passing (skipped by Phil, or unsatisfiable)
    public var warn: String?
    /// a setup event's step before the first gate: "queue", "checkout" or "env"
    public var step: String?
    /// in the queue: this run's place in line (1 = next), and what the gates slot is busy with
    public var position: Int?
    public var behind: String?
    /// in the queue: how many runs wait ahead in each tier ("interactive" = Phil's clicks, "ship",
    /// "background" = agents'), and this run's own tier
    public var ahead: [String: Int]?
    public var tier: String?
    public var note: String?

    enum K: String, CodingKey { case event, gate, gates, ok, ms, ts, warn, step, position, behind, ahead, tier, note }

    public init(event: String, gate: String? = nil, planned: [String]? = nil, verdicts: [Verdict]? = nil,
                ok: Bool? = nil, ms: Double? = nil, ts: Double? = nil, warn: String? = nil,
                step: String? = nil, position: Int? = nil, behind: String? = nil,
                ahead: [String: Int]? = nil, tier: String? = nil, note: String? = nil) {
        self.event = event; self.gate = gate; self.planned = planned; self.verdicts = verdicts
        self.ok = ok; self.ms = ms; self.ts = ts; self.warn = warn
        self.step = step; self.position = position; self.behind = behind
        self.ahead = ahead; self.tier = tier; self.note = note
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        event = (try? c.decode(String.self, forKey: .event)) ?? ""
        gate = try? c.decode(String.self, forKey: .gate)
        planned = try? c.decode([String].self, forKey: .gates)
        verdicts = planned == nil ? try? c.decode([Verdict].self, forKey: .gates) : nil
        ok = try? c.decode(Bool.self, forKey: .ok)
        ms = try? c.decode(Double.self, forKey: .ms)
        ts = try? c.decode(Double.self, forKey: .ts)
        warn = try? c.decode(String.self, forKey: .warn)
        step = try? c.decode(String.self, forKey: .step)
        position = try? c.decode(Int.self, forKey: .position)
        behind = try? c.decode(String.self, forKey: .behind)
        ahead = try? c.decode([String: Int].self, forKey: .ahead)
        tier = try? c.decode(String.self, forKey: .tier)
        note = try? c.decode(String.self, forKey: .note)
    }
}

/// GET /gates-progress.
public struct GateProgress: Decodable, Equatable, Sendable {
    public struct Tail: Decodable, Equatable, Sendable {
        public var gate: String
        public var lines: [String]
        /// seconds since the gate last wrote a line (the server stamps it from the log's mtime)
        public var age: Double?
    }

    public var running: Bool
    public var elapsed: Double?
    public var events: [GateEvent]?
    public var dead: Bool?
    public var err: String?
    /// the last lines a gate has written — the running one, or the one asked for
    public var tail: Tail?
    /// the tree the run gated: its rows are the branch's checks only while the branch is on it
    public var tree: String?

    public init(running: Bool, elapsed: Double? = nil, events: [GateEvent]? = nil, dead: Bool? = nil, err: String? = nil, tail: Tail? = nil, tree: String? = nil) {
        self.running = running; self.elapsed = elapsed; self.events = events; self.dead = dead; self.err = err; self.tail = tail; self.tree = tree
    }
}

public struct GateRow: Equatable, Sendable {
    public enum State: String, Sendable { case queued, running, green, waived, red, stopped, skipped }
    public var name: String
    public var label: String {
        switch state {
        case .skipped: "\(name) skipped"
        case .stopped: "\(name) stopped"
        case .waived: "\(name) waived"
        default: name
        }
    }
    public var state: State
    /// how long it ran, or has been running (ms)
    public var ms: Double?
    public var summary: String?
    /// a running gate: seconds since it last wrote anything — past `stuckAfter` it is stuck, not slow
    public var quiet: Double?
}

public enum GatesRun {
    /// Each planned gate's state; `now` (seconds, like the journal's ts) times a running one.
    public static func rows(_ p: GateProgress?, now: Double) -> [GateRow] {
        let ev = p?.events ?? []
        let result = ev.last { $0.event == "result" }
        var names = ev.last { $0.event == "plan" }?.planned ?? []
        for verdict in result?.verdicts ?? [] where !names.contains(verdict.name) { names.append(verdict.name) }
        let running = isRunning(p)
        if names.isEmpty, p?.dead == true, result == nil, let step = setup(p)?.step {
            return [GateRow(name: step, state: .stopped, ms: nil)]
        }
        return names.map { name in
            let done = ev.last { $0.event == "done" && $0.gate == name }
            if let verdict = result?.verdicts?.last(where: { $0.name == name }) {
                let warn = nonempty(verdict.warn) ?? nonempty(done?.warn)
                let state: GateRow.State = verdict.ok == true
                    ? (warn != nil || verdict.skipped == true || verdict.advisory == true ? .waived : .green)
                    : verdict.skipped == true ? .skipped : verdict.ok == false ? .red : .stopped
                return GateRow(name: name, state: state, ms: verdict.ms ?? done?.ms, summary: warn ?? nonempty(verdict.summary))
            }
            if let done {
                let warn = nonempty(done.warn)
                let state: GateRow.State = done.ok == true ? (warn == nil ? .green : .waived) : done.ok == false ? .red : .stopped
                return GateRow(name: name, state: state, ms: done.ms, summary: warn)
            }
            if let start = ev.last(where: { $0.event == "start" && $0.gate == name }) {
                let quiet = running && p?.tail?.gate == name ? p?.tail?.age : nil
                let end = running ? now : result?.ts
                return GateRow(name: name, state: running ? .running : .stopped,
                               ms: start.ts.flatMap { start in end.map { max(0, ($0 - start) * 1000) } }, quiet: quiet)
            }
            return GateRow(name: name, state: result != nil ? .skipped : running ? .queued : .stopped, ms: nil,
                           summary: result.flatMap { nonempty($0.note) })
        }
    }

    /// The runs in hand sorted by the branch's tree: `current` is the branch's checks, `previous` a
    /// run for a tree the branch has left — history, never drawn as this code's checks. `pushed` is
    /// the store's copy, `read` the GET /gates-progress answer (the output tail, or a server that
    /// doesn't push runs); a read without a tree is trusted only for the pushed run's tail.
    public static func split(pushed: GateProgress?, read: GateProgress?, tree: String) -> (current: GateProgress?, previous: GateProgress?) {
        var current: GateProgress?
        if var p = pushed, p.tree == tree {
            if read?.tree == nil || read?.tree == p.tree { p.tail = read?.tail }
            current = p
        } else if let r = read, r.tree == tree {
            current = r
        }
        let older = [pushed, read].compactMap { $0 }.first { $0.tree != nil && $0.tree != tree && !rows($0, now: 0).isEmpty }
        return (current, older)
    }

    /// The left tree's rows to draw, dimmed, while a run for the new tree has none of its own yet.
    public static func previousRows(current: GateProgress?, previous: GateProgress?, inFlight: Bool, now: Double) -> [GateRow] {
        guard inFlight, rows(current, now: now).isEmpty else { return [] }
        return rows(previous, now: now)
    }

    /// Whether `p` can move this run up: something waits ahead of it in line. `p` puts it at the
    /// front — ahead of Phil's earlier clicks too — so the only run it can't pass is the one running.
    public static func canPutNext(_ setup: GateEvent?) -> Bool {
        guard let setup, setup.step == "queue" else { return false }
        return (setup.position ?? 2) > 1
    }

    public static func isRunning(_ p: GateProgress?) -> Bool {
        p?.running == true && p?.dead != true && !(p?.events ?? []).contains { $0.event == "result" }
    }

    private static func nonempty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    /// The running gate that has written nothing for longer than `stuckAfter`: a wedged test
    /// holding the slot reads as stuck, not slow, without asking Claude.
    public static func stuck(_ rows: [GateRow]) -> GateRow? {
        rows.first { $0.state == .running && ($0.quiet ?? 0) > stuckAfter }
    }

    /// Whether a gate's output is shown in full: on request (`, g` names it) or when it went red.
    /// A running or passing gate's output is one line — a count — until asked (focus decides detail).
    public static func fullOutput(_ gate: String, rows: [GateRow], shown: String?) -> Bool {
        shown == gate || rows.first { $0.name == gate }?.state == .red
    }

    /// The gates a quick run left to CI (stack-gates --quick says "quick gates" in each one's warn).
    public static func quick(_ rows: [GateRow]) -> [String] {
        rows.filter { $0.state == .waived && $0.summary?.contains("quick gates") == true }.map(\.name)
    }

    /// What an in-flight run is doing while no gate is running: "gates starting" before the first
    /// gate (the server is readying the checkout or waiting for a slot), "<gate> next" between two.
    /// Nil when a gate is running, one went red, or nothing is in flight.
    public static func between(_ rows: [GateRow], inFlight: Bool, setup: GateEvent? = nil) -> String? {
        guard inFlight, !rows.contains(where: { $0.state == .running || $0.state == .red }) else { return nil }
        guard rows.contains(where: { $0.state == .green || $0.state == .waived }),
              let next = rows.first(where: { $0.state == .queued }) else { return setup.map(words) ?? "gates starting" }
        return "\(next.name) next"
    }

    /// The step an in-flight run is on before its first gate, from its latest setup event.
    public static func setup(_ p: GateProgress?) -> GateEvent? {
        let ev = p?.events ?? []
        guard !ev.contains(where: { $0.event == "plan" || $0.event == "result" }) else { return nil }
        return ev.last { $0.event == "setup" }
    }

    /// Setup that takes longer than this is stuck, not slow: a run that waits normally gets its slot or its checkout in minutes.
    public static let stuckAfter: Double = 300

    /// What the chip says between gates, how long it has said it, and whether that's long enough to be stuck.
    public static func waiting(_ p: GateProgress?, rows: [GateRow], inFlight: Bool, now: Double) -> (text: String, secs: Double?, stuck: Bool)? {
        guard p?.dead != true, !(p?.events ?? []).contains(where: { $0.event == "result" }) else { return nil }
        let step = setup(p)
        guard let text = between(rows, inFlight: inFlight, setup: step) else { return nil }
        // a time belongs to a live run only: a finished run's elapsed stood still on the chip
        // while an optimistic "running" outlived it ("gates starting · 20m 39s", 2026-11-05)
        guard let since = step?.ts else { return (text, p?.running == true ? p?.elapsed : nil, false) }
        let secs = max(0, now - since)
        return (secs > stuckAfter ? "stuck \(text)" : text, secs, secs > stuckAfter)
    }

    static func words(_ e: GateEvent) -> String {
        let busy = e.behind.flatMap { $0.isEmpty ? nil : $0 }
        switch e.step {
        case "queue":
            if let p = e.position, p > 1 {
                guard let ahead = e.ahead else {
                    return "#\(p) in line for gates\(busy.map { " · \($0) running" } ?? "") · p puts it next"
                }
                let kinds = [("interactive", "yours"), ("ship", "ready to ship"), ("background", "agent")]
                    .compactMap { k, word in ahead[k].flatMap { $0 > 0 ? "\($0) \(word)" : nil } }
                return "#\(p) in line · behind \(kinds.joined(separator: ", ")) · p puts it next"
            }
            return busy.map { "waiting on \($0)" } ?? "waiting for a gates slot"
        case "checkout": return "preparing the checkout"
        case "env": return "repairing the environment"
        default: return "gates starting"
        }
    }

    /// "42s", "3m 5s" (Ship.tsx secs).
    public static func secs(_ ms: Double?) -> String {
        guard let ms else { return "" }
        if ms >= 60000 { return "\(Int(ms / 60000))m \(Int(((ms.truncatingRemainder(dividingBy: 60000)) / 1000).rounded()))s" }
        return "\(Int((ms / 1000).rounded()))s"
    }
}
