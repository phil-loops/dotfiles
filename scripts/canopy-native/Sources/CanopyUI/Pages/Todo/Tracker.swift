import CanopyCore
import Foundation

/// One tracker item as this page reads it (types.ts TodoItem). Read from the store's raw `todo`
/// table, not the shared `TodoItem`: a file srv/todo.py can't parse arrives as
/// `{id, title, state: "broken", problems, body}` with no kind/area/size/why, which the shared model
/// can't decode (it would drop the item, and the "Can't read" section with it).
struct TrackerItem: Decodable, Equatable {
    var id: String
    var title: String
    var kind: String
    var state: String
    var area: String
    var size: String
    var why: String
    var waiting: String?
    var blocked_by: [String]?
    var links: [String]?
    var rank: Int?
    var created: String?
    var updated: String?
    var body: String
    var problems: [String]?

    init(id: String, title: String? = nil, kind: String = "build", state: String = "open", area: String = "x", size: String = "S",
         why: String = "", waiting: String? = nil, blocked_by: [String]? = nil, links: [String]? = nil, rank: Int? = nil,
         created: String? = nil, updated: String? = nil, body: String = "", problems: [String]? = nil) {
        self.id = id; self.title = title ?? id; self.kind = kind; self.state = state; self.area = area; self.size = size
        self.why = why; self.waiting = waiting; self.blocked_by = blocked_by; self.links = links; self.rank = rank
        self.created = created; self.updated = updated; self.body = body; self.problems = problems
    }

    enum K: String, CodingKey { case id, title, kind, state, area, size, why, waiting, blocked_by, links, rank, created, updated, body, problems }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? id
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? "broken"
        area = (try? c.decode(String.self, forKey: .area)) ?? ""
        size = (try? c.decode(String.self, forKey: .size)) ?? ""
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
        waiting = try? c.decode(String.self, forKey: .waiting)
        blocked_by = try? c.decode([String].self, forKey: .blocked_by)
        links = try? c.decode([String].self, forKey: .links)
        rank = (try? c.decode(Double.self, forKey: .rank)).map { Int($0) }
        created = try? c.decode(String.self, forKey: .created)
        updated = try? c.decode(String.self, forKey: .updated)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        problems = try? c.decode([String].self, forKey: .problems)
    }
}

/// The tracker page's order (tracker.ts): what needs Phil, what's under way, the ranked queue, what
/// waits on something else. Pure, so the page, the cursor and reordering agree.
enum Tracker {
    enum Section: String, CaseIterable { case broken, decide, doing, next, waiting }

    static let titles: [Section: String] = [.broken: "Can't read", .decide: "Needs you", .doing: "Doing", .next: "Next", .waiting: "Waiting"]

    static func sectionOf(_ t: TrackerItem) -> Section? {
        if t.state == "broken" { return .broken }
        if t.state == "done" || t.state == "dropped" { return nil }
        if t.state == "waiting" { return .waiting }
        if t.kind == "decide" { return .decide }
        return t.state == "doing" ? .doing : .next
    }

    /// rank (unranked last), then oldest first, then id.
    static func byQueue(_ a: TrackerItem, _ b: TrackerItem) -> Bool {
        let ra = a.rank ?? .max, rb = b.rank ?? .max
        if ra != rb { return ra < rb }
        let ca = a.created ?? "", cb = b.created ?? ""
        if ca != cb { return ca < cb }
        return a.id < b.id
    }

    /// Open items by section, each in rank order (unranked after, oldest first); empty sections left out.
    static func queue(_ items: [TrackerItem]) -> [(section: Section, items: [TrackerItem])] {
        Section.allCases.map { s in (s, items.filter { sectionOf($0) == s }.sorted(by: byQueue)) }.filter { !$0.1.isEmpty }
    }

    /// New ranks for moving `id` to position `to` within its section. The section keeps the rank
    /// numbers it already holds, so its place among /next's global ranking doesn't move; unranked
    /// items now ahead of a ranked one get numbers after every rank in use, those below stay
    /// unranked. Nil when nothing moves.
    static func rerank(_ items: [TrackerItem], id: String, to want: Int) -> [String: Int]? {
        guard let me = items.first(where: { $0.id == id }), let section = sectionOf(me) else { return nil }
        var order = items.filter { sectionOf($0) == section }.sorted(by: byQueue)
        guard let from = order.firstIndex(where: { $0.id == id }) else { return nil }
        let to = max(0, min(order.count - 1, want))
        if from == to { return nil }
        order.insert(order.remove(at: from), at: to)
        let held = order.compactMap(\.rank).sorted()
        var next = max(0, items.map { $0.rank ?? 0 }.max() ?? 0)
        let last = max(to, order.lastIndex { $0.rank != nil } ?? -1)
        var out: [String: Int] = [:]
        for (i, t) in order.prefix(last + 1).enumerated() {
            let r: Int
            if i < held.count { r = held[i] } else { next += 1; r = next }
            if t.rank != r { out[t.id] = r }
        }
        return out
    }
}

@MainActor
extension Store {
    /// Every tracker item as the user should see it (the overlay applied), broken files included.
    func trackerItems() -> [TrackerItem] {
        (raw["todo"] ?? [:]).keys.sorted().compactMap(trackerItem)
    }

    func trackerItem(_ id: String) -> TrackerItem? {
        rawView("todo", id).flatMap { try? JSONValue.object($0).decode(TrackerItem.self) }
    }

    /// The server's copy of one field, without the overlay — what `settled` checks.
    func trackerServer(_ id: String, _ field: String) -> JSONValue? {
        raw["todo"]?[id]?[field]
    }
}
