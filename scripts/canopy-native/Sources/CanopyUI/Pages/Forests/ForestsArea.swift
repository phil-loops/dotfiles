import CanopyCore
import SwiftUI

/// The forests home (/v2) and one forest's page (/v2/p/<repo>/<project>) with its story face, and
/// the forest-level writes (commands/project.ts, commands/branch.ts). Publishes `app.forestModel`.
enum ForestsArea: PageArea {
    static let name = "forests"

    static func install(_ app: AppModel) {
        app.addSurface(ForestsSurface())
        app.addSurface(ForestSurface())
        ProjectCommands.install(app)
        BranchCommands.install(app)
        ForestNav.install(app)
    }
}

struct ForestsSurface: SurfaceProvider {
    let surfaceID = "forests"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(ForestsPage()) }

    /// model.ts rows on Forests: focus lane, workbench, the archive when it's shown, and the branches
    /// of each open forest — or, filtered, only what's ready.
    func rows(_ app: AppModel) -> [String] { app.forestModel.homeRows() }

    func primary(for row: String, _ app: AppModel) -> RouteTo? { ForestNav.primary(for: row, app) }

    func scopes(_ app: AppModel) -> [Scope] {
        var out: [Scope] = []
        if RowKey.id(app.selected, "b") != nil { out.append(.branch) }
        if target(for: .project, app) != nil { out.append(.project) }
        if app.selected != nil { out.append(.row) }
        return out
    }

    func target(for scope: Scope, _ app: AppModel) -> String? {
        guard scope == .project else { return nil }
        if let p = RowKey.id(app.selected, "p") { return p }
        return RowKey.id(app.selected, "b").flatMap { app.store.view(Branch.self, $0)?.project }
    }

    func title(for row: String, _ app: AppModel) -> String? {
        if let id = RowKey.id(row, "b"), let b = app.store.view(Branch.self, id) { return "\(leaf(b.name)) \(b.description)" }
        return app.guessTitle(row)
    }
}

struct ForestSurface: SurfaceProvider {
    let surfaceID = "forest"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(ForestPage(route: route)) }

    /// The forest's branches in merge order — or the story's chapters, on that face.
    func rows(_ app: AppModel) -> [String] { app.forestModel.forestRows(app.forestModel.pageProject) }

    /// The branches, and below them the forest's open todo items (its list on the tracker).
    func panes(_ app: AppModel) -> [Pane] {
        var out = [Pane(id: "main", rows: rows(app))]
        let todo = ForestPage.todoItems(app).map { RowKey.todo($0.id) }
        if !todo.isEmpty { out.append(Pane(id: "todo", title: "todo", rows: todo, row: 1)) }
        return out
    }

    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        if let id = RowKey.id(row, "t") { return RouteTo("todo.show", arg: id) }
        return ForestNav.primary(for: row, app)
    }

    func scopes(_ app: AppModel) -> [Scope] {
        var out: [Scope] = []
        if RowKey.id(app.selected, "b") != nil { out += [.branch, .row] }
        out.append(.forest)
        if app.forestModel.pageProject != nil { out.append(.project) }
        return out
    }

    func target(for scope: Scope, _ app: AppModel) -> String? {
        switch scope {
        case .project, .forest: return app.forestModel.pageProject
        default: return nil
        }
    }

    func crumbs(_ app: AppModel, route: Route) -> [Crumb]? {
        guard let id = route.projectID else { return nil }
        return [Crumb(app.store.view(Project.self, id)?.name ?? id)]
    }

    /// What's on screen — except while `g j` asks which child at a fork: then only those children,
    /// and picking one only moves the cursor there.
    func targets(_ app: AppModel) -> [LabelTarget] {
        let all = app.visibleTargets()
        guard let kids = app.forestModel.childChoice else { return all }
        return all.filter { $0.pane == "main" && kids.contains($0.key) }.map { t in
            var t = t
            t.run = RouteTo("cursor.set", target: t.key)
            return t
        }
    }

    func title(for row: String, _ app: AppModel) -> String? {
        if let id = RowKey.id(row, "b"), let b = app.store.view(Branch.self, id) { return "\(leaf(b.name)) \(b.description)" }
        if let id = RowKey.id(row, "d"), let l = app.store.view(Landed.self, id) { return "#\(l.pr) \(OutlineHints.bare(l.title))" }
        if let id = RowKey.id(row, "t"), let t = app.store.trackerItem(id) { return t.title }
        return app.guessTitle(row)
    }

    /// The jumplist keeps which face the page showed (the cursor key is the shell's).
    func remember(_ place: inout Place, _ app: AppModel) { place.tab = app.forestModel.face.rawValue }

    func restore(_ place: Place, _ app: AppModel) {
        guard let f = place.tab.flatMap(ForestModel.Face.init(rawValue:)), f != app.forestModel.face else { return }
        let key = place.cursorKey
        app.forestModel.face = f
        if let key { app.setCursor(key) }
    }
}
