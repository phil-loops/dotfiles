import AppKit
import CanopyCore
import SwiftUI

/// The wiki (/v2/wiki[/<slug>]): durable prose about the repo (srv/wiki.py). A map page describes
/// code that exists and cites it — a citation opens its lines from origin/main beside the page. A
/// plan page describes code that doesn't exist yet, bound to its forest. The moves (commands/wiki.ts):
/// open a page (from the list, a wikilink or the finder), show a citation's lines, put them away, go
/// to the forest a plan page describes.
enum WikiArea: PageArea {
    static let name = "wiki"

    static func install(_ app: AppModel) {
        let wiki = app.state { WikiState() }
        app.addSurface(WikiSurface())
        let r = app.registry

        r.register(Command(id: "wiki.open", title: "Open the wiki page", scope: .article, verb: .main, label: "open",
                           available: { slug in wiki.page(slug) != nil },
                           local: { [weak app] slug, _ in
                               guard let app, let slug else { throw Refusal("no such page") }
                               wiki.go(slug, app)
                           }))
        r.register(Command(id: "wiki.cite", title: "Show a citation's lines on main", scope: .wiki, needsArg: true, quiet: true,
                           local: { [weak app] anchor, _ in if let app { wiki.showCite(anchor, app) } }))
        r.register(Command(id: "wiki.url", title: "Open a link from the page in the browser", scope: .wiki, needsArg: true, quiet: true,
                           local: { url, _ in
                               guard let url, let u = URL(string: url), u.scheme == "http" || u.scheme == "https" else { throw Refusal("not a web link") }
                               NSWorkspace.shared.open(u)
                           }))
        r.register(Command(id: "wiki.back", title: "Back out", scope: .wiki, verb: .cancel, label: "back", quiet: true,
                           local: { [weak app] _, _ in
                               guard let app else { return }
                               if wiki.cite != nil { wiki.closeCite(app) }
                               else if let c = app.closers.first(where: { $0.isOpen() }) { c.close() }
                               else { throw Refusal("h goes up · C-o goes back") }
                           }))
        r.register(Command(id: "wiki.forest", title: "Go to the forest this plan describes", scope: .wiki,
                           available: { [weak app] _ in app.map { wiki.planForest($0) != nil } ?? false },
                           local: { [weak app] _, _ in
                               guard let app, let p = wiki.planForest(app) else { throw Refusal("not a plan page") }
                               app.go(.forest(repo: p.repo, project: p.name))
                           }))
        r.register(Command(id: "find.wiki", title: "Open a wiki page you found", scope: .global, needsArg: true, quiet: true,
                           local: { [weak app] _, slug in
                               guard let app, let slug = slug as? String else { throw Refusal("no page") }
                               wiki.go(slug, app)
                           }))
    }
}

struct WikiSurface: SurfaceProvider {
    let surfaceID = "wiki"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(WikiView()) }

    func panes(_ app: AppModel) -> [Pane] {
        let w = app.state { WikiState() }
        var out = [Pane(id: WikiState.listPane, title: "pages", rows: w.listRows, column: 0, pageSize: 12),
                   Pane(id: WikiState.pagePane, title: "page", rows: w.pageRows(app), column: 1, pageSize: 6)]
        if w.cite != nil { out.append(Pane(id: WikiState.sourcePane, title: "source", rows: w.sourceRows, column: 2, pageSize: 20)) }
        return out
    }

    func rows(_ app: AppModel) -> [String] { app.state { WikiState() }.listRows }

    func scopes(_ app: AppModel) -> [Scope] {
        app.pane?.id == WikiState.listPane && RowKey.id(app.selected, "w") != nil ? [.article] : []
    }

    func target(for scope: Scope, _ app: AppModel) -> String? {
        scope == .article && app.pane?.id == WikiState.listPane ? RowKey.id(app.selected, "w") : nil
    }

    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        let w = app.state { WikiState() }
        if let slug = RowKey.id(row, "w") { return RouteTo("wiki.open", target: slug) }
        switch w.link(row, app)?.kind {
        case .cite(let a): return RouteTo("wiki.cite", target: a)
        case .page(let s): return RouteTo("wiki.open", target: s)
        case .url(let u): return RouteTo("wiki.url", target: u)
        case nil: return nil
        }
    }
}
