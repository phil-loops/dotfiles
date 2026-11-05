import Foundation
import Observation

/// One place the app has been (NAV.md §4.4): the page, the focused pane and its cursor row, the
/// page's tab, the cursor's height on screen, and — on a page showing code — the code place.
/// Restoring a Place puts all of it back exactly.
public struct Place: Equatable, Sendable {
    public var route: Route
    /// the focused pane's id ("main", "files", …)
    public var pane: String?
    /// the focused pane's cursor row key ("b:loops:x", a diff stop, …)
    public var cursorKey: String?
    /// the page's own face: the review tab ("files" / "commits" / "conversation"), a forest's story face
    public var tab: String?
    /// the cursor's viewport row: lines from the top of the visible area down to it, for a surface
    /// that scrolls its own (PaneList follows the cursor instead). Lines, not points, so it survives
    /// content above it changing.
    public var row: Int?

    /// The place as you'd hand it to someone else: where, but not how your window was scrolled.
    public var shared: Place {
        var p = self
        p.row = nil
        return p
    }
    /// a code place (CodeNav), when the page shows code
    public var loc: Loc?
    /// the one commit the review page is showing instead of the whole branch
    public var commit: String?
    /// the page's window the spot is in (the review page's splits), whose own jumps C-o walks
    public var window: Int?

    public init(route: Route, pane: String? = nil, cursorKey: String? = nil, tab: String? = nil, row: Int? = nil, loc: Loc? = nil) {
        self.route = route; self.pane = pane; self.cursorKey = cursorKey; self.tab = tab; self.row = row; self.loc = loc
    }

    /// The `Surface.all` id.
    public var surface: String { route.surfaceID }
    /// router.ts routeArg(): "<repo>/<branch>" on review, "<repo>/<project>" on a forest.
    public var arg: String { route.arg }
    /// The review page's `?base=` ("" for the default).
    public var base: String {
        if case .review(_, _, let b) = route { return b }
        return ""
    }

    /// The same spot, ignoring the viewport row: two consecutive entries that are the same spot collapse.
    public func sameSpot(_ o: Place) -> Bool {
        route == o.route && pane == o.pane && cursorKey == o.cursorKey && tab == o.tab && loc == o.loc && commit == o.commit && window == o.window
    }
}

/// The app-wide jumplist (NAV.md §4.4, Helix's): `C-o` back, `C-i` forward, over pages *and* code
/// places. Stack semantics: a new jump truncates the forward list; two consecutive identical spots
/// collapse into one; a step skips entries that are where you already are. Pure — the shell says
/// where it is (`here`) and puts a returned Place back.
@MainActor
@Observable
public final class Jumplist {
    public private(set) var back: [Place] = []
    public private(set) var fwd: [Place] = []
    /// The place the last jump left from — `g a` (Helix `ga`) goes there, and back again.
    public private(set) var alternate: Place?
    public var capacity = 100

    public init() {}

    /// A jump is about to leave `here`: remember it, drop the forward list (the part of it `mine`
    /// keeps: a window's jumps leave another window's alone, as Helix's per-view jumplists do).
    public func record(_ here: Place, mine: (Place) -> Bool = { _ in true }) {
        push(here)
        fwd.removeAll(where: mine)
        alternate = here
    }

    /// `C-s`: remember where you are without moving.
    public func save(_ here: Place) {
        push(here)
        fwd = []
    }

    private func push(_ p: Place) {
        if let last = back.last, last.sameSpot(p) {
            back[back.count - 1] = p
            return
        }
        back.append(p)
        if back.count > capacity { back.removeFirst(back.count - capacity) }
    }

    /// `C-o`: the place to restore — the newest entry `mine` keeps (a window's own) — or nil when
    /// there's nowhere to go. `here` moves to the forward list.
    public func goBack(from here: Place, mine: (Place) -> Bool = { _ in true }) -> Place? {
        while let i = back.lastIndex(where: mine) {
            let to = back.remove(at: i)
            if to.sameSpot(here) { continue }
            fwd.append(here)
            return to
        }
        return nil
    }

    /// `C-i`: the inverse of goBack.
    public func goForward(from here: Place, mine: (Place) -> Bool = { _ in true }) -> Place? {
        while let i = fwd.lastIndex(where: mine) {
            let to = fwd.remove(at: i)
            if to.sameSpot(here) { continue }
            push(here)
            return to
        }
        return nil
    }

    /// The `space j` picker's pick: entry `i` of `entries` (newest first), as a new jump from `here`.
    public func jump(to i: Int, from here: Place) -> Place? {
        let all = entries
        guard all.indices.contains(i) else { return nil }
        record(here)
        return all[i]
    }

    /// Every remembered place, newest first: what `space j` lists.
    public var entries: [Place] { Array(back.reversed()) + fwd }
}

/// zoxide-style frecency (NAV.md §3.9): +1 per visit, multiplied at query time by 4 (last hour),
/// 2 (last day), ½ (last week) or ¼ (older); aged by a global divisor once the total passes a cap.
public struct Frecency: Sendable {
    public struct Entry: Sendable, Equatable {
        public var rank: Double
        public var last: Date
    }

    public private(set) var entries: [String: Entry] = [:]
    public var cap: Double = 2000

    public init() {}

    public mutating func visit(_ id: String, at: Date = Date()) {
        var e = entries[id] ?? Entry(rank: 0, last: at)
        e.rank += 1
        e.last = max(e.last, at)
        entries[id] = e
        let total = entries.values.reduce(0) { $0 + $1.rank }
        if total > cap {
            let k = 0.9 * cap / total
            entries = entries.compactMapValues { var x = $0; x.rank *= k; return x.rank >= 1 ? x : nil }
        }
    }

    public func score(_ id: String, now: Date = Date()) -> Double {
        guard let e = entries[id] else { return 0 }
        let age = now.timeIntervalSince(e.last)
        let mult: Double = age < 3600 ? 4 : age < 86400 ? 2 : age < 7 * 86400 ? 0.5 : 0.25
        return e.rank * mult
    }

    /// The most recent visit among `ids`.
    public func latest(_ ids: some Sequence<String>) -> String? {
        ids.compactMap { id in entries[id].map { (id, $0.last) } }.max { $0.1 < $1.1 }?.0
    }

    /// Fuzzy × frecency: items that match `want`, the closer matches (a substring) before the
    /// scattered ones, and within each, the higher frecency (times `boost`) first; ties keep order.
    public func rank<T>(_ items: [T], _ want: String, id: (T) -> String, text: (T) -> String, boost: (T) -> Double = { _ in 1 }, now: Date = Date()) -> [T] {
        let f = want.lowercased()
        return items.enumerated()
            .compactMap { i, it -> (T, Int, Int, Double)? in
                guard let s = pickScore(text(it).lowercased(), f) else { return nil }
                return (it, s < 1000 ? 0 : 1, i, score(id(it), now: now) * boost(it))
            }
            .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.3 != b.3 ? a.3 > b.3 : a.2 < b.2 }
            .map(\.0)
    }

    /// Seed from the usage log (`.git/stack-usage.jsonl`, the router's `nav` events and every
    /// `cmd` aimed at a branch): one visit per run of consecutive events on the same branch.
    /// Every command run from a key in the usage log, by id: what the `?` sheet ranks by.
    public mutating func seedCommands(jsonl: String) {
        for line in jsonl.split(separator: "\n") where line.contains("\"cmd\"") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  o["type"] as? String == "cmd", o["via"] as? String == "key", let id = o["id"] as? String else { continue }
            visit(id, at: (o["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date.distantPast)
        }
    }

    public mutating func seed(jsonl: String) {
        var prev: String?
        for line in jsonl.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ts = (o["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date.distantPast
            var branch: String?
            if o["type"] as? String == "nav", let path = o["path"] as? String { branch = Route(path).branchID }
            if o["type"] as? String == "cmd", let t = o["target"] as? String, let id = o["id"] as? String,
               id.hasPrefix("branch.") || id.hasPrefix("review.") || id == "find.branch", t.contains(":"), !t.hasPrefix("b:") {
                branch = t
            }
            guard let b = branch else { continue }
            if b != prev { visit(b, at: ts) }
            prev = b
        }
    }
}
