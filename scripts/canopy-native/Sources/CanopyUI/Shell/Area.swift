import CanopyCore
import SwiftUI

/// One area of the UI, owned outright by one porter. `install` registers the area's commands,
/// scopes and surfaces; it runs once at launch, in `Areas.all` order. See PORTING.md.
@MainActor
public protocol PageArea {
    static var name: String { get }
    static func install(_ app: AppModel)
}

/// One routed page (a router.ts surface). The shell asks it for the page view and for what the
/// cursor and the keys need — the parts of model.ts that differ per page.
@MainActor
public protocol SurfaceProvider {
    /// A `Surface.all` id: forests, dashboard, review, todo, forest, machine, wiki, tutor.
    var surfaceID: String { get }
    func view(_ app: AppModel, route: Route) -> AnyView
    /// The rows the cursor moves through, top to bottom ("p:<id>", "b:<id>", "t:<id>", …).
    func rows(_ app: AppModel) -> [String]
    /// The narrow scopes live right now, narrowest first. The shell appends the surface's own
    /// scope (unless listed) and `global`.
    func scopes(_ app: AppModel) -> [Scope]
    /// What a command of this scope acts on; nil falls back to the shell (`row` → the selected row).
    func target(for scope: Scope, _ app: AppModel) -> String?
    /// The crumb after "canopy ›" (forest name, "branch", …); nil uses the surface title.
    func crumbs(_ app: AppModel, route: Route) -> [Crumb]?
    /// The page's focusable regions, each a list the cursor walks. Default: one pane, "main",
    /// holding `rows`. A page with a file tree beside a diff returns two; `C-w h/j/k/l` moves
    /// between them by `column`/`row`.
    func panes(_ app: AppModel) -> [Pane]
    /// What `ret` (pane.open) runs on a row: the page's "main action" for it, or nil.
    func primary(for row: String, _ app: AppModel) -> RouteTo?
    /// Every visible thing the label layer (`g w`, `f`) can put a label on, top to bottom (NAV.md §7).
    func targets(_ app: AppModel) -> [Target]
}

public extension SurfaceProvider {
    func rows(_ app: AppModel) -> [String] { [] }
    func panes(_ app: AppModel) -> [Pane] { [Pane(id: "main", rows: rows(app))] }
    func primary(for row: String, _ app: AppModel) -> RouteTo? { nil }
    func scopes(_ app: AppModel) -> [Scope] { [] }
    func target(for scope: Scope, _ app: AppModel) -> String? { nil }
    func crumbs(_ app: AppModel, route: Route) -> [Crumb]? { nil }
    func targets(_ app: AppModel) -> [Target] {
        panes(app).flatMap { p in p.rows.map { Target(pane: p.id, key: $0, primary: primary(for: $0, app)) } }
    }
}

/// One step of the header's "canopy › forest › branch"; `command` makes it a button.
public struct Crumb: Hashable {
    public var title: String
    public var command: String?
    public init(_ title: String, command: String? = nil) { self.title = title; self.command = command }
}

/// Row keys (model.ts pkey/bkey/tkey/dkey) — the cursor's vocabulary across pages.
public enum RowKey {
    public static func project(_ id: String) -> String { "p:\(id)" }
    public static func branch(_ id: String) -> String { "b:\(id)" }
    public static func todo(_ id: String) -> String { "t:\(id)" }
    public static func landed(_ id: String) -> String { "d:\(id)" }
    public static func server(_ id: String) -> String { "m:\(id)" }
    public static func wiki(_ slug: String) -> String { "w:\(slug)" }
    public static func concept(_ id: String) -> String { "c:\(id)" }
    public static func lesson(_ id: String) -> String { "s:\(id)" }

    /// The id under a key with this prefix ("b:loops:x" → "loops:x"), else nil.
    public static func id(_ key: String?, _ prefix: String) -> String? {
        guard let key, key.hasPrefix("\(prefix):") else { return nil }
        return String(key.dropFirst(prefix.count + 1))
    }
}

/// One focusable region of a page: an ordered list of row keys, placed on a grid for `C-w`.
public struct Pane: Identifiable, Equatable {
    public var id: String
    public var title: String
    public var rows: [String]
    public var column: Int
    public var row: Int
    /// rows `C-d` / `C-u` move
    public var pageSize: Int

    public init(id: String, title: String = "", rows: [String], column: Int = 0, row: Int = 0, pageSize: Int = 10) {
        self.id = id; self.title = title; self.rows = rows; self.column = column; self.row = row; self.pageSize = pageSize
    }
}

public enum Direction: String, Sendable { case left, down, up, right }
