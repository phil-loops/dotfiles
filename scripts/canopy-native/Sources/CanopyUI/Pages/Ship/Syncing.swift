import CanopyCore
import Foundation

// syncing.ts: the sync motion's rules — what makes a branch need ⟲ sync, the steps it walks in
// v1's order, and how each server answer reads as a step. Pure. The driver (SyncCommands) runs the
// steps; the ship strip draws them.

/// GET /sync — v1's fork-staleness read for one branch (srv/sync.py state).
public struct SyncFacts: Decodable, Equatable, Sendable {
    public var behind: Int
    public var syncable: Bool
    public var restack: Bool
    public var published: Bool
    public var dirty: [String]
    /// each dirty file's patch against HEAD (an untracked file's against nothing)
    public var dirtyRows: [DirtRow]?
    public var dirtyWorktree: String
    public var why: String

    public init(behind: Int = 0, syncable: Bool = false, restack: Bool = false, published: Bool = false, dirty: [String] = [],
                dirtyRows: [DirtRow]? = nil, dirtyWorktree: String = "", why: String = "") {
        self.behind = behind; self.syncable = syncable; self.restack = restack; self.published = published
        self.dirty = dirty; self.dirtyRows = dirtyRows; self.dirtyWorktree = dirtyWorktree; self.why = why
    }

    enum K: String, CodingKey { case behind, syncable, restack, published, dirty, dirtyRows, dirtyWorktree, why }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        behind = (try? c.decode(Int.self, forKey: .behind)) ?? 0
        syncable = (try? c.decode(Bool.self, forKey: .syncable)) ?? false
        restack = (try? c.decode(Bool.self, forKey: .restack)) ?? false
        published = (try? c.decode(Bool.self, forKey: .published)) ?? false
        dirty = (try? c.decode([String].self, forKey: .dirty)) ?? []
        dirtyRows = try? c.decode([DirtRow].self, forKey: .dirtyRows)
        dirtyWorktree = (try? c.decode(String.self, forKey: .dirtyWorktree)) ?? ""
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
    }
}

public struct DirtRow: Decodable, Equatable, Sendable {
    public var path: String
    public var code: String
    public var patch: String
}

/// GET /prep-route — the one motion prep would make next (srv/prep.py).
public struct PrepRoute: Decodable, Equatable, Sendable {
    public var route: String
    public var why: String
    public init(route: String, why: String = "") { self.route = route; self.why = why }
    enum K: String, CodingKey { case route, why }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        route = (try? c.decode(String.self, forKey: .route)) ?? ""
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
    }
}

public enum StepID: String, Sendable { case dirt, reseat, rebase, prep, gates, tests }
public enum StepState: String, Sendable { case idle, run, ok, fail, skip }

public struct SyncStep: Equatable, Sendable {
    public var id: StepID
    public var label: String
    public var state: StepState
    /// the step's full reason — a failure's is never cut short
    public var note: String?
    public var t0: Date?
}

/// Where a motion ended up, as the ship line says it.
public enum SyncPhase: String, Sendable {
    case running, dirt, restacking, conflict, claude, stopped, done

    /// PHASE_WORD; nil for running and done.
    public var word: String? {
        switch self {
        case .dirt: "uncommitted — fold, stash or stop"
        case .restacking: "restack queued"
        case .conflict: "conflict — with Claude"
        case .claude: "no mechanical route — with Claude"
        case .stopped: "sync stopped"
        case .running, .done: nil
        }
    }
}

public enum Syncing {
    /// Why ⟲ sync is worth a press on this branch, one short reason each — empty at rest.
    public static func needs(_ b: Branch, facts: SyncFacts? = nil, prep: PrepRoute? = nil) -> [String] {
        var out: [String] = []
        let dirty = facts?.dirty.count ?? 0
        if dirty > 0 { out.append("\(dirty) uncommitted") }
        if b.drifted { out.append("off \(b.parent)'s tip") }
        if let f = facts, f.behind > 0, f.syncable || f.restack { out.append("\(f.behind) behind main") }
        if prep?.route == "squash" { out.append("not one voiced commit") }
        if prep?.route == "additive" { out.append("diverged from its PR") }
        else if b.diverged { out.append("diverged from origin") }
        return out
    }

    /// The motion's steps, in v1's order: only the repairs this branch needs, then shape, gates, tests.
    public static func planSteps(drifted: Bool, facts: SyncFacts) -> [SyncStep] {
        var s = [SyncStep(id: .dirt, label: "working tree", state: .idle)]
        if drifted { s.append(SyncStep(id: .reseat, label: "reseat", state: .idle)) }
        if rebases(facts) { s.append(SyncStep(id: .rebase, label: facts.restack ? "restack" : "rebase", state: .idle)) }
        s.append(contentsOf: [SyncStep(id: .prep, label: "commit shape", state: .idle), SyncStep(id: .gates, label: "gates", state: .idle),
                              SyncStep(id: .tests, label: "tests", state: .idle)])
        return s
    }

    public static func rebases(_ f: SyncFacts) -> Bool { f.behind > 0 && (f.syncable || f.restack) }

    /// What a POST /sync answer means for the motion.
    public enum Rebase: Equatable, Sendable {
        case rebased(note: String?), restack(project: String), contract, conflict, refused(note: String)
    }

    public static func rebaseOf(_ ok: Bool, _ body: JSONObject) -> Rebase {
        if !ok { return .refused(note: "refused (\(str(body["err"]).shipNonEmpty ?? "stacked, or an open PR")) — the commit shape step handles it") }
        if truthy(body["restack"]) { return .restack(project: str(body["project"])) }
        if truthy(body["contract"]) { return .contract }
        if !truthy(body["rebased"]) { return .conflict }
        return .rebased(note: str(body["summary"]).shipNonEmpty)
    }

    /// What a POST /prep-push answer means: a state (nothing to push, a built vehicle) is not a failure.
    public enum Prep: Equatable, Sendable {
        case ok(note: String?), rest(note: String), claude(note: String), fail(note: String)
        public var note: String? {
            switch self { case .ok(let n): n; case .rest(let n), .claude(let n), .fail(let n): n }
        }
    }

    public static func prepOf(_ ok: Bool, _ body: JSONObject) -> Prep {
        let err = str(body["err"])
        if ok { return .ok(note: routed(body).joined(separator: " · ").shipNonEmpty) }
        if truthy(body["reconcile"]) { return .claude(note: err.shipNonEmpty ?? "no mechanical route — handing to Claude") }
        if truthy(body["vehiclePending"]) { return .rest(note: "additive vehicle already built — push it, or delete it to rebuild") }
        if err.hasPrefix("nothing to push") { return .rest(note: "nothing to push — origin already has this") }
        return .fail(note: err.shipNonEmpty ?? "prep failed")
    }

    /// POST /delta-tests as the tests step's state and note — advisory, so a failure never stops
    /// the motion. Its `ok` is the tests' verdict, so the answer is read whole, not as a refusal.
    public static func testsOf(_ body: JSONObject) -> (state: StepState, note: String) {
        if body["ran"] == nil && body["noTests"] == nil { return (.ok, "couldn't run") }
        if truthy(body["noTests"]) { return (.ok, "no changed tests") }
        if !truthy(body["ran"]) { return (.ok, str(body["summary"]).shipNonEmpty ?? "couldn't run") }
        if truthy(body["ok"]) { return (.ok, "\(num(body["passed"])) ✓") }
        return (.fail, "\(num(body["failed"])) failed (advisory — the motion went on):\n\(str(body["summary"]))")
    }

    /// Whether the prep answer sealed the outgoing commits — their words are new and want a look.
    public static func sealed(_ body: JSONObject) -> Bool { routed(body).contains { $0.hasPrefix("sealed ") } }

    static func routed(_ body: JSONObject) -> [String] { body["routed"]?.array?.compactMap(\.string) ?? [] }
    static func str(_ v: JSONValue?) -> String { v?.string ?? "" }
    static func num(_ v: JSONValue?) -> String { v?.number.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? "?" }
    /// JS truthiness for a JSON value.
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .null?: false
        case .bool(let b)?: b
        case .number(let n)?: n != 0 && !n.isNaN
        case .string(let s)?: !s.isEmpty
        case .array?, .object?: true
        }
    }
}

extension String {
    /// nil for "" — JS `x || fallback`.
    var shipNonEmpty: String? { isEmpty ? nil : self }
}
