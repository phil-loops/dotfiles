import CanopyCore
import Foundation
import Observation

extension KeyMode {
    /// `/`'s line at the foot: printable keys go to the query, the page moves as you type
    public static let search: KeyMode = "search"
}

/// `/` the Helix way: type, and the cursor jumps to the next match in the focused pane while every
/// match lights up; ↵ keeps the search (n / N then step match by match, esc clears it); esc while
/// typing puts the cursor back where it was. Lower-case queries match any case, a capital makes it
/// exact (smartcase). A match is a range in one of a row's search fields (the review diff's new and
/// old halves); landing on one tells the page, which selects it the way `w` selects a name.
@MainActor
@Observable
public final class PageSearch {
    /// One match: a row, which of its search fields, and the UTF-16 range in that field's text.
    public struct Hit: Equatable, Sendable {
        public var row: String
        public var field: Int
        public var at: Range<Int>
    }

    public internal(set) var query = ""
    public internal(set) var typing = false
    /// the match the cursor was last put on
    public internal(set) var current: Hit?
    @ObservationIgnored var pane = ""
    @ObservationIgnored var origin: String?
    /// Begun with `?`: typing lands on the match before the cursor, and n / N run the other way (Helix).
    public internal(set) var backward = false

    public static func of(_ app: AppModel) -> PageSearch { app.state { PageSearch() } }

    /// A kept (or typing) search with something in it: n / N step its matches.
    public var active: Bool { !query.isEmpty }

    /// Every place the query appears in a text, as UTF-16 ranges (smartcase).
    nonisolated public static func ranges(of query: String, in text: String) -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        let t = text as NSString, opts: NSString.CompareOptions = query == query.lowercased() ? [.caseInsensitive] : []
        var out: [Range<Int>] = []
        var from = 0
        while from < t.length {
            let r = t.range(of: query, options: opts, range: NSRange(location: from, length: t.length - from))
            if r.location == NSNotFound { break }
            out.append(r.location..<NSMaxRange(r))
            from = r.location + max(1, r.length)
        }
        return out
    }

    func fields(_ row: String, _ app: AppModel) -> [String] {
        app.provider?.searchFields(for: row, app) ?? [app.guessTitle(row)]
    }

    func hits(in row: String, _ app: AppModel) -> [Hit] {
        fields(row, app).enumerated().flatMap { f, text in Self.ranges(of: query, in: text).map { Hit(row: row, field: f, at: $0) } }
    }

    /// Every match in the searched pane, in reading order (row, then field, then position).
    public func hits(_ app: AppModel) -> [Hit] {
        guard active, let p = app.panes.first(where: { $0.id == pane }) else { return [] }
        return p.rows.flatMap { hits(in: $0, app) }
    }

    /// The searched pane's rows that match, in order.
    public func matches(_ app: AppModel) -> [String] {
        guard active, let p = app.panes.first(where: { $0.id == pane }) else { return [] }
        return p.rows.filter { !hits(in: $0, app).isEmpty }
    }

    /// The searched pane's matches by row, for the views that light them.
    public func hitsByRow(_ app: AppModel, pane id: String) -> [String: [Hit]] {
        guard id == pane else { return [:] }
        return Dictionary(grouping: hits(app), by: \.row)
    }

    func start(_ app: AppModel, backward: Bool = false) {
        self.backward = backward
        pane = app.pane?.id ?? ""
        origin = app.selected
        current = nil
        app.recordJump()
        query = ""
        typing = true
        app.keys.openLayer(.search)
    }

    /// Search for `q` from where the cursor is, kept (`*`): lands on the match at the cursor's name,
    /// else the next one. false when nothing matches.
    func seek(_ app: AppModel, _ q: String, at here: Hit?) -> Bool {
        pane = app.pane?.id ?? ""
        origin = app.selected
        query = q
        typing = false
        backward = false
        let all = hits(app)
        if let here, let same = all.first(where: { $0.row == here.row && $0.field == here.field && $0.at.contains(here.at.lowerBound) }) {
            land(app, same)
            return true
        }
        return step(app, 1)
    }

    /// Each keystroke: the first match at or after where the search began (wrapping).
    func typed(_ app: AppModel, _ q: String) {
        query = q
        guard let p = app.panes.first(where: { $0.id == pane }), !p.rows.isEmpty else { return }
        let from = origin.flatMap { p.rows.firstIndex(of: $0) } ?? 0
        let order = backward ? Array(p.rows[...from].reversed()) + Array(p.rows[(from + 1)...].reversed())
                             : Array(p.rows[from...]) + Array(p.rows[..<from])
        for row in order {
            if let hit = backward ? hits(in: row, app).last : hits(in: row, app).first { return land(app, hit) }
        }
        current = nil
        if let o = origin { app.setCursor(o) }
    }

    func land(_ app: AppModel, _ hit: Hit) {
        if app.pane?.id != pane { app.focus(pane: pane) }
        app.setCursor(hit.row)
        current = hit
        app.provider?.searchLanded(hit, app)
    }

    /// A key while typing: the engine types the query itself, like the `?` sheet's filter, so a key
    /// can't be lost to whichever view holds AppKit's focus. false: not a typing key (ret, esc, ⌃…).
    func type(_ key: String, _ app: AppModel) -> Bool {
        guard typing else { return false }
        switch key {
        case "backspace": typed(app, String(query.dropLast()))
        case "space": typed(app, query + " ")
        default:
            guard key.count == 1 else { return false }
            typed(app, query + key)
        }
        return true
    }

    func keep(_ app: AppModel) {
        typing = false
        if app.keys.layer == .search { app.keys.closeLayer() }
    }

    func cancel(_ app: AppModel) {
        typing = false
        query = ""
        current = nil
        if app.keys.layer == .search { app.keys.closeLayer() }
        if let o = origin { app.setCursor(o) }
    }

    func clear() { query = ""; current = nil }

    /// Which match the cursor is on (1-based) of how many, for the status line.
    public func tally(_ app: AppModel) -> (at: Int?, of: Int) {
        let all = hits(app)
        return (current.flatMap { c in app.selected == c.row ? all.firstIndex(of: c).map { $0 + 1 } : nil }, all.count)
    }

    /// n / N: the next match after the cursor, match by match (wrapping); false when nothing matches.
    func step(_ app: AppModel, _ dir: Int) -> Bool {
        let d = backward ? -dir : dir
        let all = hits(app)
        guard !all.isEmpty, let p = app.panes.first(where: { $0.id == pane }) else { return false }
        let rowAt = Dictionary(uniqueKeysWithValues: p.rows.enumerated().map { ($1, $0) })
        func pos(_ h: Hit) -> (Int, Int, Int) { (rowAt[h.row] ?? 0, h.field, h.at.lowerBound) }
        // from the match the cursor is on, else from the cursor's row (before its first match going down)
        let here: (Int, Int, Int)
        if let c = current, c.row == app.selected, all.contains(c) {
            here = pos(c)
        } else {
            let r = app.selected.flatMap { rowAt[$0] } ?? -1
            here = d > 0 ? (r, -1, -1) : (r, Int.max, Int.max)
        }
        let next = d > 0 ? (all.first { pos($0) > here } ?? all.first!) : (all.last { pos($0) < here } ?? all.last!)
        land(app, next)
        return true
    }
}
