import CanopyCore
import Foundation

/// Navigation on the forest pages, NAV.md's way: `ret`/`l` in and `h` out on one zoom axis, `J`/`K`
/// through merge order, `g k`/`g j` along the DAG (labels over the children at a fork), `g K`/`g J`
/// to the stack's root and tip, and `g 1–9` to the focus lane's forests (the harpoon list).
@MainActor
enum ForestNav {
    /// What `ret` does on a row — the row's one primary action (commands/project.ts row.primary).
    static func primary(for row: String?, _ app: AppModel) -> RouteTo? {
        let m = app.forestModel
        if let id = RowKey.id(row, "b") {
            guard let v = m.branchView(id) else { return nil }
            switch v.st.action {
            case .push: return RouteTo("branch.push", target: id)
            case .pr: return RouteTo("branch.pr", target: id)
            default: return RouteTo("branch.open", target: id)
            }
        }
        if let d = RowKey.id(row, "d"), app.store.view(Landed.self, d) != nil {
            return RouteTo("story.why", arg: RowKey.landed(d))
        }
        let pid = RowKey.id(row, "p") ?? (app.router.surface.id == "forest" ? m.pageProject : nil)
        guard let p = pid.flatMap({ app.store.view(Project.self, $0) }) else { return nil }
        if p.state == .archive { return RouteTo("project.restore", target: p.id) }
        if m.forest(p.id)?.closed == true { return RouteTo("project.archive", target: p.id) }
        return RouteTo("forest.page", target: p.id)
    }

    /// The page's branches in merge order that are rows right now (the story leaves landed ones out).
    static func mergeOrder(_ app: AppModel) -> [BranchView] {
        let rows = Set(app.rows)
        return (app.forestModel.forest(app.forestModel.pageProject)?.branches ?? []).filter { rows.contains(RowKey.branch($0.b.id)) }
    }

    static func here(_ app: AppModel) -> BranchView? { app.forestModel.branchView(RowKey.id(app.selected, "b")) }

    static func children(of id: String, _ app: AppModel) -> [BranchView] { mergeOrder(app).filter { $0.b.parentId == id } }

    static func parent(of v: BranchView, _ app: AppModel) -> BranchView? {
        guard let pid = v.b.parentId else { return nil }
        return mergeOrder(app).first { $0.b.id == pid }
    }

    static func go(_ v: BranchView, _ app: AppModel) { app.setCursor(RowKey.branch(v.b.id)) }

    /// The last branch of this forest you had open (the window's history, newest first), if it still exists.
    static func lastOpened(in pid: String, _ app: AppModel) -> Branch? {
        for r in [app.router.route] + app.router.back.reversed() {
            if let id = r.branchID, let b = app.store.view(Branch.self, id), b.project == pid { return b }
        }
        return nil
    }

    /// Same-move groups for the keys this area shares with the review page (NAV.md §7).
    static let sameMove: [String: [String]] = [
        "next branch": ["forest.branch.next"],
        "previous branch": ["forest.branch.prev"],
        "parent branch": ["forest.branch.parent"],
        "child branch": ["forest.branch.child"],
        "root of the stack": ["forest.branch.root"],
        "tip of the stack": ["forest.branch.tip"],
        "finish writing": ["branch.describe.save"],
    ]

    static func install(_ app: AppModel) {
        unowned let app = app
        let r = app.registry
        let m = app.forestModel
        for (group, ids) in sameMove {
            for id in ids where !(Bindings.sameMove[group]?.contains(id) ?? false) { Bindings.sameMove[group, default: []].append(id) }
        }

        let onBranch: (String?) -> Bool = { _ in here(app) != nil }

        r.register(Command(
            id: "forest.branch.next", title: "Next branch in merge order", scope: .forest, keys: ["J"], label: "branch", pair: "forest.branch.prev",
            available: { _ in !mergeOrder(app).isEmpty },
            local: { _, _ in
                let order = mergeOrder(app)
                let at = order.firstIndex { $0.b.id == here(app)?.b.id }
                guard let next = at.map({ $0 + 1 }) ?? (order.isEmpty ? nil : 0), order.indices.contains(next) else {
                    throw Refusal("the last branch in merge order")
                }
                go(order[next], app)
            }, recordsJump: true))
        r.register(Command(
            id: "forest.branch.prev", title: "Previous branch in merge order", scope: .forest, keys: ["K"], label: "branch",
            available: { _ in !mergeOrder(app).isEmpty },
            local: { _, _ in
                let order = mergeOrder(app)
                let at = order.firstIndex { $0.b.id == here(app)?.b.id }
                guard let prev = at.map({ $0 - 1 }) ?? (order.isEmpty ? nil : order.count - 1), order.indices.contains(prev) else {
                    throw Refusal("the first branch in merge order")
                }
                go(order[prev], app)
            }, recordsJump: true))
        r.register(Command(
            id: "forest.branch.parent", title: "Go to the branch's parent", scope: .forest, keys: ["g k"], label: "parent", pair: "forest.branch.child",
            available: onBranch,
            local: { _, _ in
                guard let v = here(app) else { return }
                guard let p = parent(of: v, app) else { throw Refusal("\(leaf(v.b.name)) sits on \(v.b.parent)") }
                go(p, app)
            }, recordsJump: true))
        r.register(Command(
            id: "forest.branch.child", title: "Go to the branch's child (labels at a fork)", scope: .forest, keys: ["g j"], label: "child",
            available: onBranch,
            local: { _, _ in
                guard let v = here(app) else { return }
                let kids = children(of: v.b.id, app)
                switch kids.count {
                case 0: throw Refusal("nothing builds on \(leaf(v.b.name))")
                case 1: go(kids[0], app)
                default:
                    // Graphite asks at a fork; here the label layer offers just the children
                    m.childChoice = kids.map { RowKey.branch($0.b.id) }
                    app.keys.openLayer(.labels)
                }
            }, recordsJump: true))
        r.register(Command(
            id: "forest.branch.root", title: "Go to the root of the branch's stack", scope: .forest, keys: ["g K"], label: "root", pair: "forest.branch.tip",
            available: onBranch,
            local: { _, _ in
                guard var v = here(app) else { return }
                var seen: Set<String> = [v.b.id]
                while let p = parent(of: v, app), seen.insert(p.b.id).inserted { v = p }
                go(v, app)
            }, recordsJump: true))
        r.register(Command(
            id: "forest.branch.tip", title: "Go to the tip of the branch's stack", scope: .forest, keys: ["g J"], label: "tip",
            available: onBranch,
            local: { _, _ in
                guard let v = here(app) else { return }
                var below: [BranchView] = []
                var frontier = [v.b.id]
                var seen: Set<String> = [v.b.id]
                while let id = frontier.popLast() {
                    for k in children(of: id, app) where seen.insert(k.b.id).inserted {
                        below.append(k)
                        frontier.append(k.b.id)
                    }
                }
                // past a fork the tip is the descendant that merges last
                guard let tip = below.max(by: { $0.b.order < $1.b.order }) else { throw Refusal("\(leaf(v.b.name)) is the tip") }
                go(tip, app)
            }, recordsJump: true))

        // g 1–9: the focus lane is the harpoon list — the Nth forest, at the branch you last had open in it
        for n in 1...9 {
            r.register(Command(
                id: "focus.slot.\(n)", title: "Go to focus forest \(n)", scope: .global, keys: ["g \(n)"], label: "slot \(n)", quiet: true,
                local: { _, _ in
                    let lane = m.projects().focus
                    guard lane.indices.contains(n - 1) else { throw Refusal("no focus forest \(n)") }
                    let p = lane[n - 1]
                    if let b = lastOpened(in: p.id, app) { app.go(.review(repo: b.repo, branch: b.name)) }
                    else {
                        app.go(.forest(repo: p.repo, project: p.name))
                        app.setCursor(nil)
                    }
                }, recordsJump: true))
        }
    }
}
