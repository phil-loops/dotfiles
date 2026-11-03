import CanopyCore
import Foundation
import Observation

extension KeyMode {
    /// `/`'s line at the foot: printable keys go to the query, the page moves as you type
    public static let search: KeyMode = "search"
}

/// `/` the Helix way: type, and the cursor jumps to the next row of the focused pane that matches
/// while every match lights up; ↵ keeps the search (n / N then step through its matches, esc
/// clears it); esc while typing puts the cursor back where it was. Lower-case queries match any
/// case, a capital makes it exact (smartcase).
@MainActor
@Observable
public final class PageSearch {
    public internal(set) var query = ""
    public internal(set) var typing = false
    @ObservationIgnored var pane = ""
    @ObservationIgnored var origin: String?

    public static func of(_ app: AppModel) -> PageSearch { app.state { PageSearch() } }

    /// A kept (or typing) search with something in it: n / N step its matches.
    public var active: Bool { !query.isEmpty }

    func hits(_ text: String) -> Bool {
        guard !query.isEmpty else { return false }
        return query == query.lowercased() ? text.lowercased().contains(query) : text.contains(query)
    }

    /// The focused pane's rows that match, in order.
    public func matches(_ app: AppModel) -> [String] {
        guard active, let p = app.panes.first(where: { $0.id == pane }) else { return [] }
        return p.rows.filter { hits(app.provider?.searchText(for: $0, app) ?? app.guessTitle($0)) }
    }

    func start(_ app: AppModel) {
        pane = app.pane?.id ?? ""
        origin = app.selected
        app.recordJump()
        query = ""
        typing = true
        app.keys.openLayer(.search)
    }

    /// Each keystroke: the first match at or after where the search began (wrapping).
    func typed(_ app: AppModel, _ q: String) {
        query = q
        guard let p = app.panes.first(where: { $0.id == pane }), !p.rows.isEmpty else { return }
        let from = origin.flatMap { p.rows.firstIndex(of: $0) } ?? 0
        let order = Array(p.rows[from...]) + Array(p.rows[..<from])
        if let hit = order.first(where: { hits(app.provider?.searchText(for: $0, app) ?? app.guessTitle($0)) }) {
            app.setCursor(hit)
        } else if let o = origin {
            app.setCursor(o)
        }
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
        if app.keys.layer == .search { app.keys.closeLayer() }
        if let o = origin { app.setCursor(o) }
    }

    func clear() { query = "" }

    /// n / N: the next match after the cursor (wrapping); false when nothing matches.
    func step(_ app: AppModel, _ d: Int) -> Bool {
        let ms = matches(app)
        guard !ms.isEmpty, let p = app.panes.first(where: { $0.id == pane }) else { return false }
        if app.pane?.id != pane { app.focus(pane: pane) }
        let at = app.selected.flatMap { p.rows.firstIndex(of: $0) } ?? -1
        let idx = ms.compactMap { p.rows.firstIndex(of: $0) }
        let next = d > 0 ? (idx.first { $0 > at } ?? idx.first!) : (idx.last { $0 < at } ?? idx.last!)
        app.setCursor(p.rows[next])
        return true
    }
}
