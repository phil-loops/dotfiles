import Foundation

/// A table that keeps every entity it can decode and records the ones it can't, so one malformed
/// entity (or a server field change) never drops a whole snapshot.
public struct LossyTable<T: Decodable>: Decodable {
    public var values: [String: T] = [:]
    public var failures: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        for k in c.allKeys {
            do { values[k.stringValue] = try c.decode(T.self, forKey: k) }
            catch { failures[k.stringValue] = String(describing: error) }
        }
    }
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Every known entity type's table, typed. Absent types decode as empty.
public struct TypedTables: Decodable {
    public var repo = LossyTable<Repo>()
    public var project = LossyTable<Project>()
    public var branch = LossyTable<Branch>()
    public var pr = LossyTable<Pr>()
    public var landed = LossyTable<Landed>()
    public var conv = LossyTable<Conv>()
    public var thread = LossyTable<Thread>()
    public var draft = LossyTable<Draft>()
    public var viewed = LossyTable<Viewed>()
    public var todo = LossyTable<TodoItem>()
    public var warm = LossyTable<Warm>()

    public init() {}

    enum K: String, CodingKey { case repo, project, branch, pr, landed, conv, thread, draft, viewed, todo, warm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        repo = try c.decodeIfPresent(LossyTable<Repo>.self, forKey: .repo) ?? .init()
        project = try c.decodeIfPresent(LossyTable<Project>.self, forKey: .project) ?? .init()
        branch = try c.decodeIfPresent(LossyTable<Branch>.self, forKey: .branch) ?? .init()
        pr = try c.decodeIfPresent(LossyTable<Pr>.self, forKey: .pr) ?? .init()
        landed = try c.decodeIfPresent(LossyTable<Landed>.self, forKey: .landed) ?? .init()
        conv = try c.decodeIfPresent(LossyTable<Conv>.self, forKey: .conv) ?? .init()
        thread = try c.decodeIfPresent(LossyTable<Thread>.self, forKey: .thread) ?? .init()
        draft = try c.decodeIfPresent(LossyTable<Draft>.self, forKey: .draft) ?? .init()
        viewed = try c.decodeIfPresent(LossyTable<Viewed>.self, forKey: .viewed) ?? .init()
        todo = try c.decodeIfPresent(LossyTable<TodoItem>.self, forKey: .todo) ?? .init()
        warm = try c.decodeIfPresent(LossyTable<Warm>.self, forKey: .warm) ?? .init()
    }

    /// "type/id: error" for every entity that didn't decode.
    public var failures: [String] {
        let all: [(String, [String: String])] = [
            ("repo", repo.failures), ("project", project.failures), ("branch", branch.failures), ("pr", pr.failures),
            ("landed", landed.failures), ("conv", conv.failures), ("thread", thread.failures), ("draft", draft.failures),
            ("viewed", viewed.failures), ("todo", todo.failures), ("warm", warm.failures),
        ]
        return all.flatMap { t, f in f.map { "\(t)/\($0.key): \($0.value)" } }.sorted()
    }
}

public typealias RawTables = [String: [String: JSONValue]]

/// GET /state: {epoch, versions, entities, ms}.
public struct Snapshot {
    public var epoch: String
    public var versions: Versions
    public var entities: TypedTables
    public var raw: RawTables
    public var ms: Double?

    private struct Head: Decodable { var epoch: String; var versions: Versions; var ms: Double? }
    private struct Typed: Decodable { var entities: TypedTables? }
    private struct Raw: Decodable { var entities: RawTables? }

    public init(epoch: String, versions: Versions, entities: TypedTables = .init(), raw: RawTables = [:], ms: Double? = nil) {
        self.epoch = epoch; self.versions = versions; self.entities = entities; self.raw = raw; self.ms = ms
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        let d = JSONDecoder()
        let head = try d.decode(Head.self, from: data)
        return Snapshot(
            epoch: head.epoch, versions: head.versions,
            entities: try d.decode(Typed.self, from: data).entities ?? .init(),
            raw: try d.decode(Raw.self, from: data).entities ?? [:], ms: head.ms)
    }
}

/// One `patch` event of /v2/events: {domain, version, upserts: {type: {id: obj}}, deletes: {type: [id]}}.
public struct Patch {
    public var domain: String
    public var version: Int
    public var upserts: TypedTables
    public var rawUpserts: RawTables
    public var deletes: [String: [String]]

    private struct Head: Decodable { var domain: String; var version: Int; var deletes: [String: [String]]? }
    private struct Typed: Decodable { var upserts: TypedTables? }
    private struct Raw: Decodable { var upserts: RawTables? }

    public init(domain: String, version: Int, upserts: TypedTables = .init(), rawUpserts: RawTables = [:], deletes: [String: [String]] = [:]) {
        self.domain = domain; self.version = version; self.upserts = upserts; self.rawUpserts = rawUpserts; self.deletes = deletes
    }

    public static func decode(_ data: Data) throws -> Patch {
        let d = JSONDecoder()
        let head = try d.decode(Head.self, from: data)
        return Patch(
            domain: head.domain, version: head.version,
            upserts: try d.decode(Typed.self, from: data).upserts ?? .init(),
            rawUpserts: try d.decode(Raw.self, from: data).upserts ?? [:],
            deletes: head.deletes ?? [:])
    }

    /// Build a patch from raw objects (tests, and anything synthesizing one locally).
    public static func make(domain: String, version: Int, upserts: RawTables = [:], deletes: [String: [String]] = [:]) throws -> Patch {
        let body: JSONValue = .object([
            "domain": .string(domain), "version": .number(Double(version)),
            "upserts": .object(upserts.mapValues { .object($0) }),
            "deletes": .object(deletes.mapValues { .array($0.map(JSONValue.string)) }),
        ])
        return try decode(JSONEncoder().encode(body))
    }
}

/// Each domain's version advances by exactly one; anything else is a gap (resync) or a replay.
public enum VersionCheck: String, Sendable { case ok, gap, stale }

public func checkVersion(_ have: Versions, _ p: Patch) -> VersionCheck {
    let cur = have[p.domain] ?? 0
    if p.version <= cur { return .stale }
    return p.version == cur + 1 ? .ok : .gap
}
