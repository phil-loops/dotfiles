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

    /// Every row, and the two quiet buttons: the archive fold and the ready filter's "show all".
    func targets(_ app: AppModel) -> [Target] {
        let m = app.forestModel
        var out = rows(app).map { Target(pane: "main", key: $0, primary: primary(for: $0, app)) }
        if m.readyOnly { out.insert(Target(pane: "main", key: "ctl:ready", primary: RouteTo("ready.toggle")), at: 0) }
        else if !m.showArchive && !m.projects().archive.isEmpty { out.append(Target(pane: "main", key: "ctl:archive", primary: RouteTo("archive.toggle"))) }
        return out
    }
}

struct ForestSurface: SurfaceProvider {
    let surfaceID = "forest"

    func view(_ app: AppModel, route: Route) -> AnyView { AnyView(ForestPage(route: route)) }

    /// The forest's branches in merge order — or the story's chapters, on that face.
    func rows(_ app: AppModel) -> [String] { app.forestModel.forestRows(app.forestModel.pageProject) }

    func primary(for row: String, _ app: AppModel) -> RouteTo? { ForestNav.primary(for: row, app) }

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

    /// Every row, the step in each branch's way, the merge check and the face switch. While `g j` asks
    /// which child at a fork, only those children.
    func targets(_ app: AppModel) -> [Target] {
        let m = app.forestModel
        if app.keys.layer == .labels, let kids = m.childChoice {
            return kids.map { Target(pane: "main", key: $0, primary: RouteTo("cursor.set", target: $0)) }
        }
        guard let pid = m.pageProject else { return [] }
        var out: [Target] = [Target(pane: "main", key: "ctl:face", primary: RouteTo("forest.face"))]
        if m.integratable(pid), m.verdict(pid) != nil {
            out.append(Target(pane: "main", key: "ctl:integrate:\(pid)", primary: RouteTo("forest.integrate", target: pid)))
        }
        for row in rows(app) {
            out.append(Target(pane: "main", key: row, primary: primary(for: row, app)))
            guard m.face == .branches, let id = RowKey.id(row, "b"), let v = m.branchView(id),
                  let now = Loop.steps(v.b, v.pr, v.st, words: nil).first(where: { $0.state == .now }),
                  let cmd = Loop.command(now.id) else { continue }
            out.append(Target(pane: "main", key: "step:\(id):\(now.id.rawValue)", primary: RouteTo(cmd, target: id)))
        }
        return out
    }
}
