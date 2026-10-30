import CanopyCore
import Foundation

// The seam between the review page (area B) and Ship (area C). B owns the surface, the diff, the
// tabs and the cursor stops; Ship owns the strip, the conversation, the ledger, the commits tab and
// the words. B wires Ship in with four calls in its ReviewSurface and one assignment:
//
//   ShipState.of(app).host = <B's page state>             // conforms to ShipHost
//   panes:      … + ShipSeam.panes(app)                  // the conversation / history / words panes for the tab
//   scopes:     ShipSeam.scopes(app) + …                 // thread, pending, history, commit, words — narrowest first
//   target:     ShipSeam.target(for: scope, app) ?? …    // review → the branch id, thread/pending/history/words from the row
//   primary:    ShipSeam.primary(for: row, app) ?? …     // ret on a thread folds it, on a words row writes it
//   review.back (esc): `if ShipSeam.backOut(app) { return }` first
//
// On the files tab B draws Ship's ThreadView / PendingView / ComposerView at their lines and puts
// rows "t|<thread id>" and "p|<draft item key>" among its own stops — the keys the conversation
// pane uses too — so the thread and pending commands work wherever the cursor meets one.

/// What the review page tells Ship.
@MainActor
public protocol ShipHost: AnyObject {
    /// the review page's tab: "conversation", "commits" or "files"
    var tab: String { get set }
    /// The commentable line range under the cursor (and the mark `x` dropped), or nil off a line.
    func lineRange(_ app: AppModel) -> ShipLineRange?
    /// The new side's text of `path`, lines from…to, as the diff shows them — what a suggestion replaces.
    func newLines(_ app: AppModel, path: String, from: Int, to: Int) -> [String]
    /// Put the cursor on a thread at its line (the files tab), showing outdated ones if it is.
    func showThread(_ app: AppModel, id: String)
    /// The commit whose diff shows moved (nil: the whole branch) — load and show it.
    func commitScopeChanged(_ sha: String?)
    /// history.enter / commit.back: move focus between the history list and the commit's diff.
    func focusDiff(_ app: AppModel, _ on: Bool)
    /// The cursor's line was commented or written to: drop `x`'s mark.
    func clearMark()
}

public struct ShipLineRange: Equatable, Sendable {
    public var path: String
    public var side: Side
    public var line: Int
    public var startLine: Int?
    public init(path: String, side: Side, line: Int, startLine: Int? = nil) { self.path = path; self.side = side; self.line = line; self.startLine = startLine }
}

/// Ship's own host until B sets one: it keeps the tab, and has no diff to read from.
@MainActor
public final class StandInHost: ShipHost {
    public var tab = "conversation"
    public var range: ShipLineRange?
    public init() {}
    public func lineRange(_ app: AppModel) -> ShipLineRange? { range }
    public func newLines(_ app: AppModel, path: String, from: Int, to: Int) -> [String] { [] }
    public func showThread(_ app: AppModel, id: String) {
        tab = "conversation"
        app.focus(pane: ShipSeam.conversationPane)
        app.setCursor("t|\(id)")
    }
    public func commitScopeChanged(_ sha: String?) {}
    public func focusDiff(_ app: AppModel, _ on: Bool) { app.focus(pane: on ? ShipSeam.wordsPane : ShipSeam.historyPane) }
    public func clearMark() { range = range.map { ShipLineRange(path: $0.path, side: $0.side, line: $0.line) } }
}

public extension Scope {
    /// a words row: the description, the PR's title or why, a commit's subject or body
    static let words: Scope = "words"
}

/// The address sheet (`E`): ↵/c Claude, o Helix, p pick a commit, 1–9 the commit.
public extension KeyMode {
    static let address: KeyMode = "address"
}

@MainActor
public enum ShipSeam {
    public static let conversationPane = "conversation"
    public static let historyPane = "history"
    public static let wordsPane = "words"

    /// The review page's branch id.
    public static func branchID(_ app: AppModel) -> String? {
        guard case .review = app.router.route else { return nil }
        return app.router.route.branchID
    }

    /// The panes Ship draws on the review page's current tab.
    public static func panes(_ app: AppModel) -> [Pane] {
        guard let id = branchID(app) else { return [] }
        switch ShipState.of(app).host.tab {
        case "conversation":
            return [Pane(id: conversationPane, title: "conversation", rows: ShipRows.conversation(app, id), pageSize: 8)]
        case "commits":
            return [Pane(id: historyPane, title: "commits", rows: ShipRows.history(app, id), column: 0, pageSize: 10),
                    Pane(id: wordsPane, title: "words", rows: ShipRows.words(app, id), column: 1, pageSize: 6)]
        default:
            return []
        }
    }

    /// The narrow scopes Ship makes live, narrowest first.
    public static func scopes(_ app: AppModel) -> [Scope] {
        guard branchID(app) != nil else { return [] }
        let row = app.selected ?? ""
        var out: [Scope] = []
        if row.hasPrefix("t|") { out.append(.thread) }
        if row.hasPrefix("p|") { out.append(.pending) }
        if row.hasPrefix("w|") { out.append(.words) }
        let ship = ShipState.of(app)
        if ship.host.tab == "commits" {
            if app.pane?.id == historyPane { out.append(.history) }
            else if ship.commitScope != nil { out.append(.commit) }
        }
        return out
    }

    /// What a Ship scope's command acts on.
    public static func target(for scope: Scope, _ app: AppModel) -> String? {
        let row = app.selected
        switch scope {
        case .review, .commit: return branchID(app)
        case .thread: return row.flatMap { $0.hasPrefix("t|") ? String($0.dropFirst(2)) : nil }
        case .pending: return row.flatMap { $0.hasPrefix("p|") ? String($0.dropFirst(2)) : nil }
        case .words: return row.flatMap { $0.hasPrefix("w|") ? $0 : nil }
        case .history: return branchID(app)
        default: return nil
        }
    }

    /// `ret` on a Ship row.
    public static func primary(for row: String, _ app: AppModel) -> RouteTo? {
        if row.hasPrefix("t|") { return RouteTo("review.fold", target: String(row.dropFirst(2))) }
        if row.hasPrefix("w|") { return RouteTo("words.edit", target: row) }
        if row.hasPrefix("h|") { return RouteTo("history.open", target: branchID(app)) }
        return nil
    }

    /// esc in normal on the review page: close what Ship has open, innermost first. True when it did.
    @discardableResult
    public static func backOut(_ app: AppModel) -> Bool {
        let s = ShipState.of(app)
        if app.keys.layer == .address { app.keys.closeLayer(); return true }
        if s.composer != nil { s.composer = nil; return true }
        if s.dirtOpen != nil { s.dirtOpen = nil; return true }
        if s.inspecting != nil { s.inspecting = nil; return true }
        if s.gateShown != nil { s.gateShown = nil; return true }
        if s.host.tab == "commits" && s.historyFocus == .diff { s.historyFocus = .list; s.host.focusDiff(app, false); return true }
        return false
    }

    /// Whether `backOut` has anything to close.
    public static func canBackOut(_ app: AppModel) -> Bool {
        let s = ShipState.of(app)
        return app.keys.layer == .address || s.composer != nil || s.dirtOpen != nil || s.inspecting != nil || s.gateShown != nil
    }
}

/// A branch's leaf name ("forest/queries" → "queries").
func shipLeaf(_ name: String) -> String { name.split(separator: "/").last.map(String.init) ?? name }
