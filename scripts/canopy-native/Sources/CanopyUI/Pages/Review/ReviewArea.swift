import CanopyCore
import SwiftUI

/// The review page (/v2/b/<repo>/<branch>): the diff, its cursor stops, folds, the file tree, the
/// side code pane, code navigation, the map. The Ship area's panels (ship strip, conversation,
/// history) sit inside it through the views in Pages/Ship and the `ReviewGuest` seam.
enum ReviewArea: PageArea {
    static let name = "review"

    static func install(_ app: AppModel) {
        app.addSurface(ReviewSurface())
        app.registry.addScopes([.filter], to: "review")
        DiffCommands.install(app)
        let pg = ReviewPageState.of(app)
        ShipState.of(app).host = pg
        _ = app.nav.attach(CodeNav.Attached(open: { [weak pg] l in pg?.open(l) }, here: { [weak pg] in pg?.herePlace() }))
        watch(app, pg)
    }

    /// Bring the page up to its address whenever the address (or the tip under it) moves.
    private static func watch(_ app: AppModel, _ pg: ReviewPageState) {
        withObservationTracking {
            _ = app.router.route
            if case .review = app.router.route { _ = pg.keyOf }
        } onChange: { [weak app, weak pg] in
            DispatchQueue.main.async {
                guard let app, let pg else { return }
                if case .review = app.router.route { pg.sync() }
                watch(app, pg)
            }
        }
        if case .review = app.router.route { pg.sync() }
    }
}

public extension KeyMode {
    /// the forest map over the review page (space m): j/k walk it, ↵ or l opens, h goes to the forest's page
    static let map: KeyMode = "map"
}

public extension Scope {
    /// typing into the file filter: ⌃↵ / ↵ goes to the first file it finds
    static let filter: Scope = "filter"
}

struct ReviewSurface: SurfaceProvider {
    let surfaceID = "review"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(ReviewPage(route: route)) }

    func panes(_ app: AppModel) -> [Pane] {
        let pg = ReviewPageState.of(app)
        let guest = ShipSeam.panes(app)
        switch pg.tab {
        case "conversation":
            return guest
        case "commits":
            let n = guest.map(\.column).max().map { $0 + 1 } ?? 0
            return guest + (pg.scoped ? [Pane(id: reviewDiffPane, title: "commit", rows: pg.stopKeys, column: n, pageSize: 20)] : [])
        default:
            var out = (pg.showsTree ? [Pane(id: reviewTreePane, title: "files", rows: ReviewPage.treeRows(pg), column: 0, pageSize: 12)] : [])
                + [Pane(id: reviewDiffPane, title: "diff", rows: pg.stopKeys, column: 1, pageSize: 20)]
            if pg.side != nil { out.append(Pane(id: reviewCodePane, title: pg.side.map { shortPath($0.path) } ?? "code", rows: pg.sideRows, column: 2, pageSize: 20)) }
            return out
        }
    }

    func scopes(_ app: AppModel) -> [Scope] {
        let pg = ReviewPageState.of(app)
        guard app.keys.layer != .map else { return [] }
        if app.insertField == ReviewPage.filterField { return [.filter] }
        var out = ShipSeam.scopes(app)
        if app.pane?.id == reviewDiffPane, let h = pg.here {
            let s = Scope(rawValue: h.kind.rawValue)
            if h.kind != .file, !out.contains(s) { out.append(s) }
            if pg.scoped, !out.contains(.commit) { out.append(.commit) }
        }
        return out
    }

    func target(for scope: Scope, _ app: AppModel) -> String? {
        let pg = ReviewPageState.of(app)
        if let t = ShipSeam.target(for: scope, app) { return t }
        switch scope {
        case .review, .filter: return pg.id.isEmpty ? nil : pg.id
        case .line, .gap, .thread, .pending:
            guard app.pane?.id == reviewDiffPane, let h = pg.here, h.kind.rawValue == scope.rawValue else { return nil }
            return h.kind == .line || h.kind == .gap ? h.key : h.id
        default: return nil
        }
    }

    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        let pg = ReviewPageState.of(app)
        if let r = ShipSeam.primary(for: row, app) { return r }
        if app.pane?.id == reviewTreePane, row.hasPrefix("f|") { return RouteTo("review.file.go", arg: String(row.dropFirst(2))) }
        if row.hasPrefix("g|") { return RouteTo("review.expand", target: row) }
        return nil
    }

    func title(for row: String, _ app: AppModel) -> String? {
        let pg = ReviewPageState.of(app)
        if row.hasPrefix("f|") { return String(row.dropFirst(2)) }
        if row.hasPrefix("s:"), let n = Int(row.dropFirst(2)), let t = pg.sideText {
            let lines = t.components(separatedBy: "\n")
            return n <= lines.count ? "\(n) \(lines[n - 1].trimmingCharacters(in: .whitespaces))" : row
        }
        guard let i = pg.stopIndex[row] else { return app.guessTitle(row) }
        let s = pg.stops[i]
        switch s.kind {
        case .line:
            let l = s.row.flatMap { $0.right ?? $0.left }
            return "\(shortPath(s.path)):\(l?.new ?? l?.old ?? 0) \(l?.text.trimmingCharacters(in: .whitespaces) ?? "")"
        case .gap: return "⋯ hidden lines in \(shortPath(s.path))"
        case .thread:
            let t = s.id.flatMap { app.store.view(CanopyCore.Thread.self, $0) }
            return "\(t?.comments.first?.author ?? "thread") on \(shortPath(s.path)): \(Markdown.plain(t?.comments.first?.body ?? "", max: 80))"
        case .pending:
            return "draft: \(pg.items.first { $0.key == s.id }?.body.prefix(80) ?? "")"
        case .file: return s.path
        }
    }

    func targets(_ app: AppModel) -> [LabelTarget] {
        let pg = ReviewPageState.of(app)
        var out = app.visibleTargets()
        let rows = pg.stopIndex
        for (key, rect) in pg.diffCanvas.canvas.visibleTargets() where rows[key] != nil {
            out.append(LabelTarget(pane: reviewDiffPane, key: key, rect: rect, title: title(for: key, app) ?? key))
        }
        if pg.side != nil {
            for (key, rect) in pg.sideCanvas.canvas.visibleTargets() {
                out.append(LabelTarget(pane: reviewCodePane, key: key, rect: rect, title: title(for: key, app) ?? key))
            }
        }
        return out
    }

    func remember(_ place: inout Place, _ app: AppModel) {
        place.tab = ReviewPageState.of(app).tab
    }

    func restore(_ place: Place, _ app: AppModel) {
        let pg = ReviewPageState.of(app)
        if let tab = place.tab, tab != pg.tab {
            pg.tab = tab
            if let p = place.pane { app.focus(pane: p) }
            if let k = place.cursorKey { app.setCursor(k) }
        }
        if place.pane == reviewDiffPane, let k = place.cursorKey, pg.stopIndex[k] == nil { pg.pendingCursor = (pg.id, k) }
        pg.cursorMoved &+= 1
    }

    func crumbs(_ app: AppModel, route: Route) -> [Crumb]? {
        guard case .review(let repo, let name, _) = route else { return nil }
        if let p = Route.integrationOf(name) {
            return [Crumb(app.store.view(Project.self, "\(repo):\(p)")?.name ?? p, command: "review.leave"), Crumb("✦ the whole forest")]
        }
        let b = route.branchID.flatMap { app.store.view(Branch.self, $0) }
        let forest = b.flatMap { app.store.view(Project.self, $0.project) }?.name
        return (forest.map { [Crumb($0, command: "review.leave")] } ?? []) + [Crumb(b?.name ?? name)]
    }
}

func shortPath(_ p: String) -> String { p.split(separator: "/").last.map(String.init) ?? p }
