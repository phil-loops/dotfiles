import CanopyCore
import SwiftUI

/// The forests home (/v2) and one forest's page (/v2/p/<repo>/<project>) with its story face.
/// The home is the worked example of the page contract: rows for the cursor, scopes, targets.
enum ForestsArea: PageArea {
    static let name = "forests"

    static func install(_ app: AppModel) {
        app.addSurface(ForestsSurface())
        app.addSurface(ForestSurface())
    }
}

struct ForestsSurface: SurfaceProvider {
    let surfaceID = "forests"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(ForestsPage()) }

    /// model.ts rows on Forests: each open forest, focus lane then workbench (the archive fold and
    /// expanded branches come with the port).
    func rows(_ app: AppModel) -> [String] {
        let p = ForestsPage.projects(app.store)
        return (p.focus + p.workbench).map { RowKey.project($0.id) }
    }

    /// ret on a forest opens its page.
    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        RowKey.id(row, "p").map { RouteTo("find.forest", arg: $0) }
    }

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
}

struct ForestSurface: SurfaceProvider {
    let surfaceID = "forest"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(ForestPage(route: route)) }

    /// The forest's branches in merge order.
    func rows(_ app: AppModel) -> [String] {
        ForestPage.branches(app.store, app.router.route).map { RowKey.branch($0.id) }
    }

    /// ret on a branch opens its review page.
    func primary(for row: String, _ app: AppModel) -> RouteTo? {
        RowKey.id(row, "b").map { RouteTo("find.branch", arg: $0) }
    }

    func scopes(_ app: AppModel) -> [Scope] {
        var out: [Scope] = []
        if RowKey.id(app.selected, "b") != nil { out += [.branch, .row] }
        out.append(.forest)
        if let id = app.router.route.projectID, app.store.view(Project.self, id) != nil { out.append(.project) }
        return out
    }

    func target(for scope: Scope, _ app: AppModel) -> String? {
        if scope == .project, let id = app.router.route.projectID, app.store.view(Project.self, id) != nil { return id }
        return nil
    }

    func crumbs(_ app: AppModel, route: Route) -> [Crumb]? {
        guard let id = route.projectID else { return nil }
        return [Crumb(app.store.view(Project.self, id)?.name ?? id)]
    }
}
