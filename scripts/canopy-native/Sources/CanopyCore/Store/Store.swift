import Foundation
import Observation

/// One pending optimistic change: these fields of this entity, until the runner drops it.
public struct Op: Sendable, Equatable {
    public var seq: Int
    public var type: EntityType
    public var id: String
    public var fields: JSONObject

    public init(seq: Int = 0, type: EntityType, id: String, fields: JSONObject) {
        self.seq = seq; self.type = type; self.id = id; self.fields = fields
    }
}

public enum Conn: String, Sendable { case connecting, live, down }

/// The one local store of the world — a port of v2/store.ts: normalized entities hydrated from
/// /state and patched from /v2/events (EventStream drives both), plus the optimistic overlay the
/// runner layers on top. Views read through `view()` / `list()`, so an optimistic change and a
/// server patch look the same.
@MainActor
@Observable
public final class Store {
    public private(set) var ready = false
    public private(set) var epoch = ""
    public private(set) var versions: Versions = [Domain.git: 0, Domain.remote: 0, Domain.review: 0, Domain.todo: 0]
    public var conn: Conn = .connecting

    public private(set) var repo: [String: Repo] = [:]
    public private(set) var project: [String: Project] = [:]
    public private(set) var branch: [String: Branch] = [:]
    public private(set) var pr: [String: Pr] = [:]
    public private(set) var landed: [String: Landed] = [:]
    public private(set) var conv: [String: Conv] = [:]
    public private(set) var thread: [String: Thread] = [:]
    public private(set) var draft: [String: Draft] = [:]
    public private(set) var viewed: [String: Viewed] = [:]
    public private(set) var todo: [String: TodoItem] = [:]
    public private(set) var warm: [String: Warm] = [:]
    /// Every entity's raw JSON, by type then id — including types the client doesn't model yet.
    public private(set) var raw: RawTables = [:]

    public private(set) var ops: [Op] = []
    /// Entities the last hydrate or patch couldn't decode ("type/id: error"). Empty when healthy.
    public private(set) var decodeFailures: [String] = []

    @ObservationIgnored private var listeners: [Int: () -> Void] = [:]
    @ObservationIgnored private var nextListener = 0

    public init() {}

    // ── change listeners ──

    /// Called after every hydrate or patch — the runner reconciles pending commands here.
    @discardableResult
    public func onChange(_ fn: @escaping () -> Void) -> () -> Void {
        nextListener += 1
        let k = nextListener
        listeners[k] = fn
        return { [weak self] in self?.listeners[k] = nil }
    }

    private func changed() { for fn in listeners.values { fn() } }

    /// Something read outside the store moved (the machine's servers): pending writes re-check.
    public func nudge() { changed() }

    // ── hydrate / patch ──

    public func hydrate(_ s: Snapshot) {
        let e = s.entities
        repo = e.repo.values; project = e.project.values; branch = e.branch.values; pr = e.pr.values
        landed = e.landed.values; conv = e.conv.values; thread = e.thread.values; draft = e.draft.values
        viewed = e.viewed.values; todo = e.todo.values; warm = e.warm.values
        raw = s.raw
        decodeFailures = e.failures
        epoch = s.epoch
        versions = s.versions
        ready = true
        changed()
    }

    /// Apply a server patch; `.gap` or `.stale` means it wasn't applied (gap → resync).
    @discardableResult
    public func applyPatch(_ p: Patch) -> VersionCheck {
        let v = checkVersion(versions, p)
        guard v == .ok else { return v }
        let u = p.upserts
        let d = p.deletes
        Self.merge(&repo, d["repo"], u.repo)
        Self.merge(&project, d["project"], u.project)
        Self.merge(&branch, d["branch"], u.branch)
        Self.merge(&pr, d["pr"], u.pr)
        Self.merge(&landed, d["landed"], u.landed)
        Self.merge(&conv, d["conv"], u.conv)
        Self.merge(&thread, d["thread"], u.thread)
        Self.merge(&draft, d["draft"], u.draft)
        Self.merge(&viewed, d["viewed"], u.viewed)
        Self.merge(&todo, d["todo"], u.todo)
        Self.merge(&warm, d["warm"], u.warm)
        for t in Set(d.keys).union(p.rawUpserts.keys) {
            var table = raw[t] ?? [:]
            for id in d[t] ?? [] { table[id] = nil }
            for (id, obj) in p.rawUpserts[t] ?? [:] { table[id] = obj }
            raw[t] = table
        }
        let failed = u.failures
        if !failed.isEmpty { decodeFailures = Array((decodeFailures + failed).suffix(50)) }
        versions[p.domain] = p.version
        changed()
        return .ok
    }

    private static func merge<T>(_ table: inout [String: T], _ deletes: [String]?, _ upserts: LossyTable<T>) {
        guard deletes?.isEmpty == false || !upserts.values.isEmpty || !upserts.failures.isEmpty else { return }
        for id in deletes ?? [] { table[id] = nil }
        for (id, obj) in upserts.values { table[id] = obj }
        // an upsert that didn't decode still replaces the old copy: a stale typed entity would lie
        for id in upserts.failures.keys { table[id] = nil }
    }

    // ── the optimistic overlay ──

    public func addOps(_ new: [Op]) { ops.append(contentsOf: new) }
    public func dropOps(seq: Int) { ops.removeAll { $0.seq == seq } }

    // ── reads ──

    /// The server's copy of every entity of a type, without the overlay.
    public func table<T: Entity>(_: T.Type) -> [String: T] {
        switch T.kind {
        case .repo: return repo as! [String: T]
        case .project: return project as! [String: T]
        case .branch: return branch as! [String: T]
        case .pr: return pr as! [String: T]
        case .landed: return landed as! [String: T]
        case .conv: return conv as! [String: T]
        case .thread: return thread as! [String: T]
        case .draft: return draft as! [String: T]
        case .viewed: return viewed as! [String: T]
        case .todo: return todo as! [String: T]
        case .warm: return warm as! [String: T]
        }
    }

    /// The entity as the user should see it: the server's copy with pending changes on top.
    public func view<T: Entity>(_ t: T.Type, _ id: String) -> T? {
        guard let base = table(t)[id] else { return nil }
        let mine = ops.filter { $0.type == T.kind && $0.id == id }
        if mine.isEmpty { return base }
        guard var obj = raw[T.kind.rawValue]?[id]?.object else { return base }
        for op in mine { obj.merge(op.fields) { $1 } }
        return (try? JSONValue.object(obj).decode(T.self)) ?? base
    }

    /// Every entity of a type through `view`, sorted by id (callers sort for display).
    public func list<T: Entity>(_ t: T.Type) -> [T] {
        table(t).keys.sorted().compactMap { view(t, $0) }
    }

    /// An entity's raw JSON object with the overlay applied — for fields the shared models lack.
    public func rawView(_ type: String, _ id: String) -> JSONObject? {
        guard var obj = raw[type]?[id]?.object else { return nil }
        for op in ops where op.type.rawValue == type && op.id == id { obj.merge(op.fields) { $1 } }
        return obj
    }

    public var counts: [String: Int] {
        Dictionary(uniqueKeysWithValues: EntityType.allCases.map { t in (t.rawValue, raw[t.rawValue]?.count ?? 0) })
    }
}
