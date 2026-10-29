import CanopyCore
import Foundation

// A tutor session as the page reads it (lesson.ts; srv/tutor.py, scripts/learning.py): the
// learner's concept graph, the session's turns, and a turn split into prose and the fenced blocks
// the page draws instead of text — tutor-pin (code to show), tutor-options (answers to pick),
// tutor-rung (what's being tested), tutor-evidence (what the turn recorded), tutor-map,
// tutor-restate, tutor-question, tutor-sim. Map, evidence and calibration are applied to the graph
// by the server when a turn ends. Pure.

struct Msg: Codable, Equatable, Sendable {
    /// "tutor" | "me"
    var role: String
    var text: String
    static func tutor(_ t: String) -> Msg { Msg(role: "tutor", text: t) }
    static func me(_ t: String) -> Msg { Msg(role: "me", text: t) }
}

struct Pin: Codable, Equatable, Hashable, Sendable {
    var path: String
    var ref: String?
    var lines: [Int]?
    var lit: (Int, Int)? { lines.flatMap { $0.count >= 2 ? ($0[0], $0[1]) : nil } }
}

/// A session, kept by this app only (the web app keeps its own in localStorage `tutor:sessions:v1`).
struct Session: Codable, Equatable, Sendable {
    var id: String
    var target: String
    var created: Double
    /// the claude session a turn resumes
    var sessionId: String
    var msgs: [Msg]
    var topic: String?
    /// the turn streaming now — the next launch re-attaches to it
    var pendingTurn: String?
    var error: String?
    var saved: Bool?
    /// a picked-up terminal session's worktree — its claude session resumes only there
    var cwd: String?
    /// the next turn forks the terminal session instead of resuming it in place
    var forkNext: Bool?
    /// the instructions version this claude session has seen (a resume drops --append-system-prompt)
    var primed: String?
    var lastActive: Double?
    var importedFrom: String?

    var touched: Double { lastActive ?? created }
}

struct TerminalSession: Decodable, Equatable, Sendable {
    var session: String
    var cwd: String
    var target: String
    var mtime: Double
    var answers: Int
    var last: String
}

struct ImportReply: Decodable, Sendable {
    var session: String?
    var cwd: String?
    var target: String?
    var msgs: [Msg]?
    var err: String?
}

struct CodeSrc: Decodable, Equatable, Sendable {
    var path: String?
    var ref: String?
    var text: String?
    var err: String?
}

struct Mastery: Decodable, Equatable, Sendable {
    var depth = 0
    var assisted = 0
    var level = ""
    var evidence = 0
    var last = ""
    var due = false
    var reason = ""
    var open_miss = ""
    var held: Int?
    var held_level: String?
    var miss_confidence: String?
    var contrast: String?

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        depth = (try? c.decode(Int.self, forKey: .depth)) ?? 0
        assisted = (try? c.decode(Int.self, forKey: .assisted)) ?? 0
        level = (try? c.decode(String.self, forKey: .level)) ?? ""
        evidence = (try? c.decode(Int.self, forKey: .evidence)) ?? 0
        last = (try? c.decode(String.self, forKey: .last)) ?? ""
        due = (try? c.decode(Bool.self, forKey: .due)) ?? false
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        open_miss = (try? c.decode(String.self, forKey: .open_miss)) ?? ""
        held = try? c.decode(Int.self, forKey: .held)
        held_level = try? c.decode(String.self, forKey: .held_level)
        miss_confidence = try? c.decode(String.self, forKey: .miss_confidence)
        contrast = try? c.decode(String.self, forKey: .contrast)
    }
    enum K: String, CodingKey { case depth, assisted, level, evidence, last, due, reason, open_miss, held, held_level, miss_confidence, contrast }
}

struct ConceptCode: Decodable, Equatable, Sendable {
    var path: String
    var ref: String?
    var lines: [Int]?
}

struct Concept: Decodable, Equatable, Sendable {
    var id: String
    var name: String
    var statement: String
    /// "principle" | "convention"
    var kind: String
    var builds_on: [String]
    var built_on_by: [String]
    var analogs: [String]
    var code: [ConceptCode]
    var topics: [String]
    var mastery: Mastery
    var blocked_by: [String]?
    var statement_learner: String?
    var restated: String?

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        statement = (try? c.decode(String.self, forKey: .statement)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "principle"
        builds_on = (try? c.decode([String].self, forKey: .builds_on)) ?? []
        built_on_by = (try? c.decode([String].self, forKey: .built_on_by)) ?? []
        analogs = (try? c.decode([String].self, forKey: .analogs)) ?? []
        code = (try? c.decode([ConceptCode].self, forKey: .code)) ?? []
        topics = (try? c.decode([String].self, forKey: .topics)) ?? []
        mastery = (try? c.decode(Mastery.self, forKey: .mastery)) ?? Mastery()
        blocked_by = try? c.decode([String].self, forKey: .blocked_by)
        statement_learner = try? c.decode(String.self, forKey: .statement_learner)
        restated = try? c.decode(String.self, forKey: .restated)
    }
    enum K: String, CodingKey { case id, name, statement, kind, builds_on, built_on_by, analogs, code, topics, mastery, blocked_by, statement_learner, restated }
}

struct Topic: Decodable, Equatable, Sendable {
    struct Stage: Decodable, Equatable, Sendable { var name: String; var concepts: [String] }
    struct Progress: Decodable, Equatable, Sendable { var held: Int; var shown: Int?; var total: Int }
    var id: String
    var title: String
    var source: String
    var stages: [Stage]
    var progress: Progress
    var updated: String?

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? id
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        stages = (try? c.decode([Stage].self, forKey: .stages)) ?? []
        progress = (try? c.decode(Progress.self, forKey: .progress)) ?? Progress(held: 0, shown: nil, total: 0)
        updated = try? c.decode(String.self, forKey: .updated)
    }
    enum K: String, CodingKey { case id, title, source, stages, progress, updated }
}

struct Evidence: Decodable, Equatable, Sendable {
    var id: String
    var concept: String
    var level: String
    var credit: String
    /// "hit" | "miss"
    var outcome: String
    var note: String
    var at: String
    var topic: String
    var session: String
    var confidence: String?
    var rung: String?
    var contrast: String?
    var via: String?

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func s(_ k: K) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        id = s(.id); concept = s(.concept); level = s(.level); credit = s(.credit); outcome = s(.outcome)
        note = s(.note); at = s(.at); topic = s(.topic); session = s(.session)
        confidence = try? c.decode(String.self, forKey: .confidence)
        rung = try? c.decode(String.self, forKey: .rung)
        contrast = try? c.decode(String.self, forKey: .contrast)
        via = try? c.decode(String.self, forKey: .via)
    }
    enum K: String, CodingKey { case id, concept, level, credit, outcome, note, at, topic, session, confidence, rung, contrast, via }

    /// A field by its wire name, for the audit's undo ("" when unset).
    func field(_ k: String) -> String {
        switch k {
        case "concept": concept
        case "level": level
        case "credit": credit
        case "outcome": outcome
        case "note": note
        case "confidence": confidence ?? ""
        case "contrast": contrast ?? ""
        case "via": via ?? ""
        case "rung": rung ?? ""
        default: ""
        }
    }
}

struct Question: Decodable, Equatable, Sendable {
    var id: String
    var text: String
    var concept: String
    var topic: String
    var asked: String
    /// "open" | "answered"
    var status: String
}

/// GET /learning-state — the fields the page reads; the rest (systems, standards, …) are ignored.
struct LearnState: Decodable, Equatable, Sendable {
    var concepts: [String: Concept]
    var topics: [String: Topic]
    var due: [String]
    var questions: [Question]
    var evidence: [Evidence]

    init(concepts: [String: Concept] = [:], topics: [String: Topic] = [:], due: [String] = [], questions: [Question] = [], evidence: [Evidence] = []) {
        self.concepts = concepts; self.topics = topics; self.due = due; self.questions = questions; self.evidence = evidence
    }
    init(from d: Decoder) throws {
        // entry by entry: one malformed concept or credit drops itself, never the whole graph
        let c = try d.container(keyedBy: K.self)
        func table<T: Decodable>(_ k: K) -> [String: T] {
            ((try? c.decode([String: JSONValue].self, forKey: k)) ?? [:]).compactMapValues { try? $0.decode(T.self) }
        }
        func list<T: Decodable>(_ k: K) -> [T] {
            ((try? c.decode([JSONValue].self, forKey: k)) ?? []).compactMap { try? $0.decode(T.self) }
        }
        concepts = table(.concepts)
        topics = table(.topics)
        due = list(.due)
        questions = list(.questions)
        evidence = list(.evidence)
    }
    enum K: String, CodingKey { case concepts, topics, due, questions, evidence }
}

enum Lesson {
    static let levels = ["predict", "explain", "transfer", "critique"]
    static let credits = ["unaided", "scaffolded", "handed"]
    static let confidences = ["low", "medium", "high"]
    static let levelHint: [String: String] = [
        "predict": "said what happens in a situation",
        "explain": "said why",
        "transfer": "handled it cold in a new setting",
        "critique": "spotted it, or its absence, in real code",
    ]
}

struct EvidenceBlock: Equatable, Sendable {
    var concept: String
    var level: String
    var credit: String
    var outcome: String
    var note: String
    var confidence: String
    var contrast: String
    var via: String
}

struct Divergence: Equatable, Hashable, Sendable {
    var event: String
    /// "skipped" | "double" | "pinned" (as the sim says it; a block may carry anything)
    var kind: String
}

enum Seg: Equatable, Sendable {
    case prose(String)
    case pin(Pin)
    case options([String])
    case rung(concept: String, level: String, rung: String, confidence: Bool, via: String, contrastOf: String)
    case evidence([EvidenceBlock])
    case map(title: String, count: Int)
    case restate(concept: String, text: String)
    case question(concept: String, text: String)
    /// a projection scenario frozen before its reveal; `off` names the safeguards switched off
    case sim(scenario: String, off: [String])
    /// the learner's answer to a sim, played: what the system did
    case simResult(scenario: String, off: [String], outcome: String, divergence: [Divergence])
    case quiet

    enum Kind: String { case prose, pin, options, rung, evidence, map, restate, question, sim, simResult, quiet }

    var kind: Kind {
        switch self {
        case .prose: .prose
        case .pin: .pin
        case .options: .options
        case .rung: .rung
        case .evidence: .evidence
        case .map: .map
        case .restate: .restate
        case .question: .question
        case .sim: .sim
        case .simResult: .simResult
        case .quiet: .quiet
        }
    }
}

// ── JavaScript's coercions, so the blocks read exactly as the web app reads them ──

/// `String(v ?? fallback)`.
func jsString(_ v: JSONValue?, _ fallback: String = "") -> String {
    guard let v, !v.isNull else { return fallback }
    switch v {
    case .null: return fallback
    case .bool(let b): return b ? "true" : "false"
    case .number(let n):
        if n.isNaN { return "NaN" }
        if n.rounded() == n, abs(n) < 1e21 { return String(Int64(n)) }
        return String(n)
    case .string(let s): return s
    case .array(let a): return a.map { $0.isNull ? "" : jsString($0) }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

/// JavaScript truthiness.
func jsTruthy(_ v: JSONValue?) -> Bool {
    guard let v else { return false }
    switch v {
    case .null: return false
    case .bool(let b): return b
    case .number(let n): return n != 0 && !n.isNaN
    case .string(let s): return !s.isEmpty
    case .array, .object: return true
    }
}

private func jsNumber(_ v: JSONValue?) -> Int {
    switch v {
    case .number(let n)?: return n.isFinite ? Int(n) : 0
    case .string(let s)?: return Int(Double(s.trimmingCharacters(in: .whitespaces)) ?? 0)
    case .bool(let b)?: return b ? 1 : 0
    default: return 0
    }
}

/// UTF-16 slicing, as JavaScript's `slice`.
extension String {
    var u16: Int { (self as NSString).length }
    func js(_ from: Int, _ to: Int? = nil) -> String {
        let ns = self as NSString
        let a = max(0, min(from, ns.length)), b = max(a, min(to ?? ns.length, ns.length))
        return ns.substring(with: NSRange(location: a, length: b - a))
    }
}

private func parseJSON(_ s: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
}

/// The safeguards a block's `kernels` switches off. JSON objects arrive unordered here, so they're
/// listed in the sim's own kernel order (unknown names after, alphabetically) — the web app lists
/// them in the block's key order.
private func offOf(_ k: JSONValue?) -> [String] {
    guard let o = k?.object else { return [] }
    let off = o.filter { $0.value == .bool(false) }.map(\.key)
    let order = Kernel.allCases.map(\.rawValue)
    return off.sorted { a, b in
        let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
        return ia != ib ? ia < ib : a < b
    }
}

private func asList(_ v: JSONValue?) -> [String] {
    guard let a = v?.array else { return [] }
    return a.map { jsString($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private let fence = try! NSRegularExpression(
    pattern: "```tutor-(pin|options|rung|evidence|map|calibration|restate|question|ledger|sim-result|sim)[ \\t]*\\r?\\n([\\s\\S]*?)```")

extension Lesson {
    /// A turn as prose and blocks. A fence still streaming in (no closing ```) is held back, never flashed as JSON.
    static func segments(_ input: String) -> [Seg] {
        var text = input
        let ns0 = text as NSString
        let open = ns0.range(of: "```tutor-", options: .backwards)
        if open.location != NSNotFound, !text.js(open.location + 9).contains("```") { text = text.js(0, open.location) }
        let ns = text as NSString
        var out: [Seg] = []
        var last = 0
        for m in fence.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(.prose(text.js(last, m.range.location))) }
            last = m.range.location + m.range.length
            let kind = ns.substring(with: m.range(at: 1))
            guard let data = parseJSON(ns.substring(with: m.range(at: 2))) else {
                out.append(.prose(ns.substring(with: m.range)))
                continue
            }
            let d = data.object ?? [:]
            if kind == "pin", let path = d["path"]?.string {
                var lines: [Int]?
                if let l = d["lines"]?.array, l.count >= 1 {
                    let a = jsNumber(l[0])
                    let b = l.count > 1 && !l[1].isNull ? jsNumber(l[1]) : a
                    lines = [a, b]
                }
                out.append(.pin(Pin(path: path, ref: jsTruthy(d["ref"]) ? jsString(d["ref"]) : nil, lines: lines)))
            } else if kind == "options" {
                out.append(.options(asList(data)))
            } else if kind == "rung", jsTruthy(d["concept"]) {
                out.append(.rung(concept: jsString(d["concept"]), level: jsString(d["level"]), rung: jsString(d["rung"]),
                                 confidence: d["confidence"] == .bool(true), via: jsString(d["via"]), contrastOf: jsString(d["contrast_of"])))
            } else if kind == "evidence" {
                let items = (data.array ?? [data]).map { e -> EvidenceBlock in
                    let x = e.object ?? [:]
                    return EvidenceBlock(concept: jsString(x["concept"]), level: jsString(x["level"]), credit: jsString(x["credit"], "unaided"),
                                         outcome: jsString(x["outcome"], "hit"), note: jsString(x["note"]), confidence: jsString(x["confidence"]),
                                         contrast: jsString(x["contrast"]), via: jsString(x["via"]))
                }.filter { !$0.concept.isEmpty }
                out.append(.evidence(items))
            } else if kind == "sim", let scenario = d["scenario"]?.string {
                out.append(.sim(scenario: scenario, off: offOf(d["kernels"])))
            } else if kind == "sim-result", let scenario = d["scenario"]?.string {
                let div = (d["divergence"]?.array ?? []).map { x in Divergence(event: jsString(x["event"]), kind: jsString(x["kind"])) }
                out.append(.simResult(scenario: scenario, off: offOf(d["kernels"]), outcome: jsString(d["outcome"]), divergence: div))
            } else if kind == "map" {
                let t = d["topic"]?.object ?? [:]
                let title = !(t["title"]?.isNull ?? true) ? jsString(t["title"]) : !(t["id"]?.isNull ?? true) ? jsString(t["id"]) : "topic"
                let stages = d["stages"]?.array ?? []
                out.append(.map(title: title, count: stages.reduce(0) { $0 + ($1["concepts"]?.array?.count ?? 0) }))
            } else if kind == "restate" || kind == "question" {
                for x in data.array ?? [data] {
                    let r: JSONObject = x.string.map { ["text": .string($0)] } ?? (x.object ?? [:])
                    guard jsTruthy(r["text"]) else { continue }
                    let concept = jsString(r["concept"]), t = jsString(r["text"])
                    out.append(kind == "restate" ? .restate(concept: concept, text: t) : .question(concept: concept, text: t))
                }
            } else {
                out.append(.quiet) // calibration, and the retired ledger in old sessions
            }
        }
        if last < ns.length { out.append(.prose(text.js(last))) }
        return out
    }

    /// The fence the tab appends to an answer once it has played the sim: the tutor copies it into its evidence.
    static func simResultFence(scenario: String, off: [String], outcome: String, divergence: [Divergence]) -> String {
        func q(_ s: String) -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: (try? e.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        let kernels = "{" + off.map { "\(q($0)):false" }.joined(separator: ",") + "}"
        let div = "[" + divergence.map { "{\"event\":\(q($0.event)),\"kind\":\(q($0.kind))}" }.joined(separator: ",") + "]"
        return "```tutor-sim-result\n{\"scenario\":\(q(scenario)),\"kernels\":\(kernels),\"outcome\":\(q(outcome)),\"divergence\":\(div)}\n```"
    }

    private static func proseOf(_ text: String) -> [String] {
        segments(text).compactMap { if case .prose(let t) = $0 { return t }; return nil }
    }

    /// What the learner said, without the machine fences the tab added to it.
    static func spoken(_ text: String) -> String {
        proseOf(text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ s: String, _ pattern: String, _ with: String) -> String {
        s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }

    private static func cap(_ s: String, _ n: Int) -> String {
        s.u16 > n ? s.js(0, n - 3) + "…" : s
    }

    /// The one line a folded rung shows: the question it asked (its last "?" sentence), else its opening.
    static func askOf(_ text: String) -> String {
        var prose = proseOf(text).joined(separator: " ")
        prose = replace(prose, "```[\\s\\S]*?```", " ")
        prose = replace(prose, "[*_`#>|]", "")
        prose = replace(prose, "\\s+", " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let re = try! NSRegularExpression(pattern: "[^.?!]*\\?")
        let asks = re.matches(in: prose, range: NSRange(location: 0, length: prose.u16)).map { (prose as NSString).substring(with: $0.range) }
        let line = (asks.last ?? prose).trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = cap(line, 160)
        return capped.isEmpty ? "(no text)" : capped
    }

    /// The whole paragraph holding a turn's last question, as asked.
    static func questionOf(_ text: String) -> String {
        let paras = proseOf(text)
            .flatMap { $0.components(separatedBy: try! NSRegularExpression(pattern: "\\n\\s*\\n")) }
            .map { replace(replace($0, "[*_`#>|]", ""), "\\s+", " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let q = paras.reversed().first { $0.contains("?") } ?? paras.last ?? ""
        return cap(q, 420)
    }

    /// The newest block of a kind across the tutor's turns.
    static func latest(_ msgs: [Msg], _ kind: Seg.Kind) -> Seg? {
        for m in msgs.reversed() where m.role == "tutor" {
            if let hit = segments(m.text).last(where: { $0.kind == kind }) { return hit }
        }
        return nil
    }

    struct Rung: Equatable { var n: Int; var tutorIdx: Int; var answer: String? }

    /// A rung is one tutor turn and the answer that followed it.
    static func rungsOf(_ msgs: [Msg]) -> [Rung] {
        var out: [Rung] = []
        for (i, m) in msgs.enumerated() where m.role == "tutor" {
            let next = i + 1 < msgs.count ? msgs[i + 1] : nil
            out.append(Rung(n: out.count + 1, tutorIdx: i, answer: next?.role == "me" ? next?.text : nil))
        }
        return out
    }

    /// Complete server-sent-event frames off the front of a buffer; what's left is a frame still arriving.
    static func sseFrames(_ input: String) -> (frames: [SSEFrame], rest: String) {
        var buf = input
        var frames: [SSEFrame] = []
        while let nl = buf.range(of: "\n\n") {
            let frame = String(buf[..<nl.lowerBound])
            buf = String(buf[nl.upperBound...])
            var event = "message", data = ""
            for ln in frame.components(separatedBy: "\n") {
                if ln.hasPrefix("event:") { event = String(ln.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                else if ln.hasPrefix("data:") { data += String(ln.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            }
            if !data.isEmpty { frames.append(SSEFrame(event: event, data: data)) }
        }
        return (frames, buf)
    }

    /// A concept's depth in words, for the pips' caption.
    static func pipsTitle(_ m: Mastery) -> String {
        var parts: [String] = []
        if let h = m.held, h != 0 { parts.append("held at \(m.held_level ?? "") (two days)") }
        if m.depth != 0 && (m.held ?? 0) < m.depth { parts.append("shown once at \(m.level)") }
        if m.depth == 0 { parts.append("not yet shown unaided") }
        if m.assisted > m.depth, levels.indices.contains(m.assisted - 1) { parts.append("\(levels[m.assisted - 1]) with help") }
        if !m.open_miss.isEmpty { parts.append("open miss\(m.miss_confidence == "high" ? " (confident)" : "")") }
        if m.due { parts.append("due: \(m.reason)") }
        return parts.joined(separator: " · ")
    }

    /// How long ago, in ms since the epoch (as the web app stores times).
    static func ago(_ ms: Double, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let m = Int(((now - ms) / 60_000 + 0.5).rounded(.down)) // Math.round
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        let h = Int((Double(m) / 60 + 0.5).rounded(.down))
        if h < 24 { return "\(h) h ago" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

private extension String {
    func components(separatedBy re: NSRegularExpression) -> [String] {
        let ns = self as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }
}
