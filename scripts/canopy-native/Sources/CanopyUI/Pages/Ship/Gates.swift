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

    enum K: String, CodingKey { case event, gate, gates, ok, ms, ts, warn }

    public init(event: String, gate: String? = nil, planned: [String]? = nil, verdicts: [Verdict]? = nil,
                ok: Bool? = nil, ms: Double? = nil, ts: Double? = nil, warn: String? = nil) {
        self.event = event; self.gate = gate; self.planned = planned; self.verdicts = verdicts
        self.ok = ok; self.ms = ms; self.ts = ts; self.warn = warn
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

    /// "42s", "3m 5s" (Ship.tsx secs).
    public static func secs(_ ms: Double?) -> String {
        guard let ms else { return "" }
        if ms >= 60000 { return "\(Int(ms / 60000))m \(Int(((ms.truncatingRemainder(dividingBy: 60000)) / 1000).rounded()))s" }
        return "\(Int((ms / 1000).rounded()))s"
    }
}
