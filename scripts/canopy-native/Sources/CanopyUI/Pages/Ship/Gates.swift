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

    enum K: String, CodingKey { case event, gate, gates, ok, ms, ts, warn, step, position, behind }

    public init(event: String, gate: String? = nil, planned: [String]? = nil, verdicts: [Verdict]? = nil,
                ok: Bool? = nil, ms: Double? = nil, ts: Double? = nil, warn: String? = nil,
                step: String? = nil, position: Int? = nil, behind: String? = nil) {
        self.event = event; self.gate = gate; self.planned = planned; self.verdicts = verdicts
        self.ok = ok; self.ms = ms; self.ts = ts; self.warn = warn
        self.step = step; self.position = position; self.behind = behind
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
    }
}

/// GET /gates-progress.
public struct GateProgress: Decodable, Equatable, Sendable {
    public struct Tail: Decodable, Equatable, Sendable {
        public var gate: String
        public var lines: [String]
    }

    public var running: Bool
    public var elapsed: Double?
    public var events: [GateEvent]?
    public var dead: Bool?
    public var err: String?
    /// the last lines a gate has written — the running one, or the one asked for
    public var tail: Tail?

    public init(running: Bool, elapsed: Double? = nil, events: [GateEvent]? = nil, dead: Bool? = nil, err: String? = nil, tail: Tail? = nil) {
        self.running = running; self.elapsed = elapsed; self.events = events; self.dead = dead; self.err = err; self.tail = tail
    }
}

public struct GateRow: Equatable, Sendable {
    public enum State: String, Sendable { case queued, running, green, waived, red, stopped }
    public var name: String
    public var state: State
    /// how long it ran, or has been running (ms)
    public var ms: Double?
    public var summary: String?
}

public enum GatesRun {
    /// Each planned gate's state; `now` (seconds, like the journal's ts) times a running one.
    public static func rows(_ p: GateProgress?, now: Double) -> [GateRow] {
        let ev = p?.events ?? []
        let plan = ev.first { $0.event == "plan" }?.planned ?? []
        let result = ev.first { $0.event == "result" }
        var summaries: [String: String] = [:]
        for g in result?.verdicts ?? [] { if let s = g.summary, summaries[g.name] == nil { summaries[g.name] = s } }
        let running = p?.running ?? false
        return plan.map { name in
            if let done = ev.first(where: { $0.event == "done" && $0.gate == name }) {
                if let w = done.warn, !w.isEmpty { return GateRow(name: name, state: .waived, ms: done.ms, summary: w) }
                let s = summaries[name].flatMap { $0.isEmpty ? nil : $0 }
                return GateRow(name: name, state: done.ok == true ? .green : .red, ms: done.ms, summary: s)
            }
            if let start = ev.first(where: { $0.event == "start" && $0.gate == name }) {
                return GateRow(name: name, state: running ? .running : .stopped, ms: start.ts.map { max(0, (now - $0) * 1000) })
            }
            return GateRow(name: name, state: running ? .queued : .stopped, ms: nil)
        }
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
        guard !ev.contains(where: { $0.event == "plan" }) else { return nil }
        return ev.last { $0.event == "setup" }
    }

    /// Setup that takes longer than this is stuck, not slow: a run that waits normally gets its slot or its checkout in minutes.
    public static let stuckAfter: Double = 300

    /// What the chip says between gates, how long it has said it, and whether that's long enough to be stuck.
    public static func waiting(_ p: GateProgress?, rows: [GateRow], inFlight: Bool, now: Double) -> (text: String, secs: Double?, stuck: Bool)? {
        let step = setup(p)
        guard let text = between(rows, inFlight: inFlight, setup: step) else { return nil }
        guard let since = step?.ts else { return (text, p?.elapsed, false) }
        let secs = max(0, now - since)
        return (secs > stuckAfter ? "stuck \(text)" : text, secs, secs > stuckAfter)
    }

    static func words(_ e: GateEvent) -> String {
        let busy = e.behind.flatMap { $0.isEmpty ? nil : $0 }
        switch e.step {
        case "queue":
            if let p = e.position, p > 1 { return "#\(p) in line for gates\(busy.map { " · \($0) running" } ?? "")" }
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
