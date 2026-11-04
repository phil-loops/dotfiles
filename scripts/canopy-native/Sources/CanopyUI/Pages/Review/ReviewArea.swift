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
        placeInSheet(app.registry)
        let pg = ReviewPageState.of(app)
        ShipState.of(app).host = pg
        _ = app.nav.attach(CodeNav.Attached(open: { [weak pg] l in pg?.open(l) }, here: { [weak pg] in pg?.herePlace() }))
        // space c's conversation is a layer over the diff: esc takes it away before anything older
        app.addCloser(first: true, isOpen: { [weak app, weak pg] in app?.router.route.surfaceID == "review" && pg?.tab == "conversation" },
                      close: { [weak app, weak pg] in
                          pg?.tab = "files"
                          app?.focus(pane: reviewDiffPane)
                      })
        watch(app, pg)
    }

    /// The page's own keys that no verb places in the `?` sheet (`KeyGroup.of` places the rest).
    private static func placeInSheet(_ r: CommandRegistry) {
        r.place(.show, ["review.in", "review.back", "review.history", "review.outdated", "review.base.parent", "review.base.main",
                        "review.base.outgoing", "review.gates.show", "review.viewed", "review.unviewed"])
        r.place(.branch, ["review.compose.edit", "review.compose.send", "review.compose.draft", "review.compose.suggest", "review.send.all",
                          "review.address.claude", "review.address.pick.list"])
        r.place(.others, ["review.map.open"])
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
            var out: [Pane] = []
            if pg.showsHistory, let id = ShipSeam.branchID(app) {
                out.append(Pane(id: ShipSeam.historyPane, title: "commits", rows: ShipRows.history(app, id), column: 0, row: 0, pageSize: 10))
            }
            if pg.showsTree { out.append(Pane(id: reviewTreePane, title: "files", rows: ReviewPage.treeRows(pg), column: 0, row: 1, pageSize: 12)) }
            out.append(Pane(id: reviewDiffPane, title: "diff", rows: pg.stopKeys, column: 1, pageSize: 20))
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

    /// In the diff `/` reads code only — a line's new half (field 0), and its old half (field 1) where
    /// that's a removed line, as far as it's drawn; headers, conversations and gaps aren't searched.
    /// The code beside the diff: each line's text. Elsewhere (the file tree): titles.
    func searchFields(for row: String, _ app: AppModel) -> [String] {
        let pg = ReviewPageState.of(app)
        switch PageSearch.of(app).pane {
        case reviewDiffPane:
            guard let i = pg.stopIndex[row], pg.stops[i].kind == .line, let r = pg.stops[i].row else { return [] }
            let w = pg.splitWidth(pg.stops[i].path)
            let old = r.left.flatMap { $0.kind == .del ? $0.text : nil }.map { $0.count > w ? String($0.prefix(max(0, w - 1))) : $0 }
            return [r.right?.text ?? "", old ?? ""]
        case reviewCodePane:
            guard let n = RowKey.id(row, "s").flatMap(Int.init), let t = pg.sideText else { return [] }
            let lines = t.components(separatedBy: "\n")
            return n >= 1 && n <= lines.count ? [lines[n - 1]] : []
        default:
            return [searchText(for: row, app) ?? app.guessTitle(row)]
        }
    }

    /// Landing on a match selects it, as `w` selects a name — so g d, space k and space o m act on it.
    func searchLanded(_ hit: PageSearch.Hit, _ app: AppModel) {
        let pg = ReviewPageState.of(app)
        switch PageSearch.of(app).pane {
        case reviewDiffPane:
            let side: Side = hit.field == 0 ? .right : .left
            pg.column = side
            pg.word = (hit.row, side, hit.at)
            pg.cursorMoved &+= 1
        case reviewCodePane:
            if let n = RowKey.id(hit.row, "s").flatMap(Int.init) { pg.sideWord = (n, hit.at) }
        default: break
        }
    }

    /// A line matches on its code, both halves; everything else on its title.
    func searchText(for row: String, _ app: AppModel) -> String? {
        let pg = ReviewPageState.of(app)
        if let i = pg.stopIndex[row], pg.stops[i].kind == .line, let r = pg.stops[i].row {
            return [r.left?.text, r.right?.text].compactMap { $0 }.joined(separator: "\n")
        }
        return title(for: row, app)
    }

    func position(_ app: AppModel) -> String? {
        let pg = ReviewPageState.of(app)
        guard app.pane?.id == reviewDiffPane, let s = pg.here, let f = pg.files.firstIndex(where: { $0.path == s.path }) else { return nil }
        var out = pg.files.count > 1 ? "file \(f + 1) of \(pg.files.count)" : shortPath(s.path)
        let hunks = pg.files[f].hunks.count
        if let h = s.row?.hunk, hunks > 1 { out += " · change \(h + 1) of \(hunks)" }
        if let l = s.row.map({ sideLine($0, prefer: pg.column) }) { out += " · line \(l.line)" }
        return out
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
        let pg = ReviewPageState.of(app)
        place.tab = pg.tab
        if pg.tab == "files", app.pane?.id == reviewDiffPane, let k = pg.diffCursor {
            place.row = pg.diffCanvas.canvas.viewportRow(of: k)
        }
    }

    func restore(_ place: Place, _ app: AppModel) {
        let pg = ReviewPageState.of(app)
        if let tab = place.tab, tab != pg.tab {
            pg.tab = tab
            if let p = place.pane { app.focus(pane: p) }
            if let k = place.cursorKey { app.setCursor(k) }
        }
        // an address names no pane: what it names is in the diff
        if place.pane == nil, place.cursorKey != nil { app.focus(pane: reviewDiffPane); app.setCursor(place.cursorKey) }
        if (place.pane ?? reviewDiffPane) == reviewDiffPane, let k = place.cursorKey, !pg.diffHere || pg.stopIndex[k] == nil { pg.pendingCursor = (pg.id, k) }
        pg.pendingRow = nil
        pg.diffCanvas.canvas.anchor = nil
        if let row = place.row, (place.pane ?? reviewDiffPane) == reviewDiffPane, (place.tab ?? "files") == "files" {
            if pg.pendingCursor?.id == pg.id || pg.pendingLoc?.id == pg.id { pg.pendingRow = (pg.id, row) } else if pg.side == nil { pg.anchor(row: row) }
        }
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
