import CanopyCore
import Foundation

/// The tracker page's order (tracker.ts): what needs Phil, what's under way, the ranked queue, what
/// waits on something else. Pure, so the page, the cursor and reordering agree.
enum Tracker {
    enum Section: String, CaseIterable { case broken, decide, doing, next, waiting }

    static let titles: [Section: String] = [.broken: "Can't read", .decide: "Needs you", .doing: "Doing", .next: "Next", .waiting: "Waiting"]

    static func sectionOf(_ t: TodoItem) -> Section? {
        if t.state == "broken" { return .broken }
        if t.state == "done" || t.state == "dropped" { return nil }
        if t.state == "waiting" { return .waiting }
        if t.kind == "decide" { return .decide }
        return t.state == "doing" ? .doing : .next
    }

    /// rank (unranked last), then oldest first, then id.
    static func byQueue(_ a: TodoItem, _ b: TodoItem) -> Bool {
        let ra = a.rank ?? .max, rb = b.rank ?? .max
        if ra != rb { return ra < rb }
        let ca = a.created ?? "", cb = b.created ?? ""
        if ca != cb { return ca < cb }
        return a.id < b.id
    }

    /// Open items by section, each in rank order (unranked after, oldest first); empty sections left out.
    static func queue(_ items: [TodoItem]) -> [(section: Section, items: [TodoItem])] {
        Section.allCases.map { s in (s, items.filter { sectionOf($0) == s }.sorted(by: byQueue)) }.filter { !$0.1.isEmpty }
    }

    /// New ranks for moving `id` to position `to` within its section. The section keeps the rank
    /// numbers it already holds, so its place among /next's global ranking doesn't move; unranked
    /// items now ahead of a ranked one get numbers after every rank in use, those below stay
    /// unranked. Nil when nothing moves.
    static func rerank(_ items: [TodoItem], id: String, to want: Int) -> [String: Int]? {
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
    func trackerItems() -> [TodoItem] { list(TodoItem.self) }

    func trackerItem(_ id: String) -> TodoItem? { view(TodoItem.self, id) }

    /// The server's copy of one field, without the overlay — what `settled` checks.
    func trackerServer(_ id: String, _ field: String) -> JSONValue? {
        raw["todo"]?[id]?[field]
    }
}
