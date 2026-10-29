import CanopyCore
import Foundation
import Observation

/// The tracker page's own state (ui.ts todoOpen): which items show their notes.
@MainActor
@Observable
final class TrackerUI {
    var open: Set<String> = []
}

/// What `todo.state` puts back (the inverse of start/done/drop).
struct TodoStateArg {
    var state: String
    var rank: Int?
}

/// The tracker's levers (commands/todo.ts): open an item, start it, finish or drop it, reorder the
/// queue (POST /todo-item). Ranking the whole queue and writing next steps is /next's job.
@MainActor
enum TodoCommands {
    static func install(_ app: AppModel) {
        let r = app.registry
        let s = app.store
        let ui = app.state { TrackerUI() }
        let exists: (String?) -> Bool = { [weak s] id in id.flatMap { s?.trackerItem($0) } != nil }
        let closed: Set<String> = ["done", "dropped", "broken"]
        weak var wapp = app

        func moveTo(_ state: String, said: ((TodoItem) -> String)? = nil) -> (String, Any?) throws -> Write? {
            { [weak s] id, _ in
                guard let s, let t = s.trackerItem(id), t.state.rawValue != state else { return nil }
                let closing = state == "done" || state == "dropped"
                let fields: JSONObject = closing ? ["state": .string(state), "rank": .null] : ["state": .string(state)]
                let back = TodoStateArg(state: t.state.rawValue, rank: t.rank)
                return Write(ops: [Op(type: .todo, id: id, fields: fields)], path: "/todo-item",
                             body: ["id": .string(id), "set": ["state": .string(state)]],
                             settled: { [weak s] in s?.trackerServer(id, "state")?.string == state },
                             said: said?(t), failed: "couldn't mark \(t.title) \(state)",
                             inverse: { _ in Inverse(id: "todo.state", target: id, arg: back) })
            }
        }

        r.register(Command(id: "todo.open", title: "Show or hide the item's notes", scope: .item, keys: ["ret"], label: "open",
                           available: exists,
                           local: { [weak ui] id, _ in
                               guard let ui, let id else { return }
                               if ui.open.contains(id) { ui.open.remove(id) } else { ui.open.insert(id) }
                           }))
        r.register(Command(id: "todo.start", title: "Start the item", scope: .item, budget: .configWrite, keys: ["I"], label: "start",
                           available: { [weak s] id in id.flatMap { s?.trackerItem($0) }?.state == "open" },
                           write: moveTo("doing")))
        r.register(Command(id: "todo.done", title: "Mark the item done", scope: .item, budget: .configWrite, keys: ["D"], label: "done",
                           available: { [weak s] id in id.flatMap { s?.trackerItem($0) }.map { !closed.contains($0.state.rawValue) } ?? false },
                           write: moveTo("done") { "done: \($0.title) — u puts it back" }))
        r.register(Command(id: "todo.drop", title: "Drop the item", scope: .item, budget: .configWrite, keys: ["X"], label: "drop",
                           available: { [weak s] id in id.flatMap { s?.trackerItem($0) }.map { !closed.contains($0.state.rawValue) } ?? false },
                           write: moveTo("dropped") { "dropped: \($0.title) — u puts it back" }))
        r.register(Command(
            id: "todo.state", title: "Put an item back as it was", scope: .item, budget: .configWrite, needsArg: true, quiet: true,
            write: { [weak s] id, arg in
                guard let s, let a = arg as? TodoStateArg, let t = s.trackerItem(id) else { return nil }
                var set: JSONObject = ["state": .string(a.state)]
                if let rank = a.rank { set["rank"] = .number(Double(rank)) }
                return Write(ops: [Op(type: .todo, id: id, fields: ["state": .string(a.state), "rank": a.rank.map { .number(Double($0)) } ?? .null])],
                             path: "/todo-item", body: ["id": .string(id), "set": .object(set)],
                             settled: { [weak s] in s?.trackerServer(id, "state")?.string == a.state },
                             said: "back: \(t.title)", failed: "couldn't put \(t.title) back")
            }))

        // ── the queue's order ──

        func ranksWrite(_ id: String, _ ranks: [String: Int?], failed: String, inverse: Inverse? = nil) -> Write {
            wapp?.setCursor(RowKey.todo(id))
            let json: JSONObject = ranks.mapValues { $0.map { .number(Double($0)) } ?? .null }
            return Write(ops: ranks.keys.sorted().map { Op(type: .todo, id: $0, fields: ["rank": json[$0]!]) },
                         path: "/todo-item", body: ["ranks": .object(json)],
                         settled: { [weak s] in ranks.allSatisfy { i, r in s?.trackerServer(i, "rank")?.int == r } },
                         failed: failed, inverse: inverse.map { inv in { _ in inv } })
        }

        func move(_ id: String, by: Int) -> Write? {
            let items = s.trackerItems()
            guard let me = s.trackerItem(id), let section = Tracker.sectionOf(me),
                  let at = Tracker.queue(items).first(where: { $0.section == section })?.items.firstIndex(where: { $0.id == id }),
                  let ranks = Tracker.rerank(items, id: id, to: at + by)
            else { return nil }
            let before: [String: Int?] = Dictionary(uniqueKeysWithValues: ranks.keys.map { ($0, s.trackerItem($0)?.rank) })
            return ranksWrite(id, ranks.mapValues { Optional($0) }, failed: "couldn't move \(me.title)",
                              inverse: Inverse(id: "todo.ranks", target: id, arg: before))
        }

        let movable: (String?) -> Bool = { [weak s] id in
            guard let t = id.flatMap({ s?.trackerItem($0) }) else { return false }
            return Tracker.sectionOf(t) != nil && t.state != "broken"
        }
        r.register(Command(id: "todo.up", title: "Move up the queue", scope: .item, budget: .configWrite, keys: ["C-k"], label: "move", pair: "todo.down",
                           available: movable, write: { id, _ in move(id, by: -1) }))
        r.register(Command(id: "todo.down", title: "Move down the queue", scope: .item, budget: .configWrite, keys: ["C-j"], label: "move",
                           available: movable, write: { id, _ in move(id, by: 1) }))
        r.register(Command(id: "todo.ranks", title: "Put the queue's order back", scope: .item, budget: .configWrite, needsArg: true, quiet: true,
                           write: { id, arg in
                               guard let ranks = arg as? [String: Int?] else { return nil }
                               return ranksWrite(id, ranks, failed: "couldn't put the order back")
                           }))
    }
}
