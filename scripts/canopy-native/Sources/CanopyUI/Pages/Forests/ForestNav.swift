import CanopyCore
import Foundation

/// Navigation on the forest pages, NAV.md's way: `ret` in and `-` out on one zoom axis, `J`/`K`
/// through merge order, `g k`/`g j` along the DAG (labels over the children at a fork), `g K`/`g J`
/// to the stack's root and tip, `space f` to find on the page. (`g 1–9` is the shell's.)
@MainActor
enum ForestNav {
    /// What `ret` does on a row: opens it. Pushing, the PR, archiving each have their own key.
    static func primary(for row: String?, _ app: AppModel) -> RouteTo? {
        let m = app.forestModel
        if let id = RowKey.id(row, "b") {
            return m.branchView(id) == nil ? nil : RouteTo("branch.open", target: id)
        }
        if let r = m.reviewRequest(row) { return RouteTo("forests.review.open", target: String(r.number)) }
        if let v = m.openPR(row) { return RouteTo("branch.open", target: v.b.id) }
        if let p = m.myPR(row) { return RouteTo("forests.mypr.open", target: String(p.number)) }
        if let r = m.reply(row) { return RouteTo("chat.focus", arg: r.chat.id) }
        if let d = RowKey.id(row, "d"), app.store.view(Landed.self, d) != nil {
            return RouteTo("story.why", arg: RowKey.landed(d))
        }
        let pid = RowKey.id(row, "p") ?? (app.router.surface.id == "forest" ? m.pageProject : nil)
        guard let p = pid.flatMap({ app.store.view(Project.self, $0) }) else { return nil }
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

    static func install(_ app: AppModel) {
        unowned let app = app
        let r = app.registry
        let m = app.forestModel
        let ancestry = ForestAncestry.of(app)
        app.addCloser(first: true, isOpen: { ancestry.waiting }, close: {
            ancestry.cancel()
            app.runner.say("navigation cancelled")
        })

        let onBranch: (String?) -> Bool = { _ in here(app) != nil }

        // ] o / [ o: the open PRs in the home's order, from any page — from one of them, the one after it
        func hopPR(_ step: Int) throws {
            let rows = m.openPRRows()
            guard !rows.isEmpty else { throw Refusal("no open PRs") }
            var at: Int?
            if case .review(let repo, let branch, _) = app.router.route {
                at = rows.firstIndex { r in
                    if let v = r.branch { return v.b.repo == repo && v.b.name == branch }
                    return r.mine.map { branch == $0.head || branch == "review/pr-\($0.number)" } ?? false
                }
            }
            at = at ?? rows.firstIndex { $0.key == app.selected }
                ?? RowKey.id(app.selected, "b").flatMap { id in rows.firstIndex { $0.branch?.b.id == id } }
            let forestsOwnPR = at == nil ? RowKey.id(app.selected, "p").flatMap { pid in rows.firstIndex { $0.branch?.b.project == pid } } : nil
            let row = rows[forestsOwnPR ?? at.map { ($0 + step + rows.count) % rows.count } ?? (step > 0 ? 0 : rows.count - 1)]
            if let v = row.branch { app.go(.review(repo: v.b.repo, branch: v.b.name)) }
            else if let p = row.mine { openOnGitHub(p.number, p.url) }
        }
        // ⌥1–⌥9: open PR n's review from any page, by the number on its card
        for n in 1...9 {
            r.register(Command(id: "forests.pr.\(n)", title: "Review open PR \(n)", scope: .global, verb: .pr(n), label: "PR \(n)", recordsJump: true,
                               available: { _ in m.homeSections().cards.count >= n },
                               local: { _, _ in
                                   let cards = m.homeSections().cards
                                   guard cards.indices.contains(n - 1) else { throw Refusal("no open PR \(n)") }
                                   let row = cards[n - 1]
                                   if let v = row.branch { app.go(.review(repo: v.b.repo, branch: v.b.name)) }
                                   else if let p = row.mine { openOnGitHub(p.number, p.url) }
                               }))
        }
        // ⌥a–⌥g: open the n-th PR you're asked to review, by the letter on its card
        for n in 1...Verbs.askedLetters.count {
            r.register(Command(id: "forests.asked.\(Verbs.askedLetters[n - 1])", title: "Open review request \(Verbs.askedLetters[n - 1])", scope: .global,
                               verb: .asked(n), label: "review \(Verbs.askedLetters[n - 1])", recordsJump: true,
                               available: { _ in m.reviewRequests.count >= n },
                               local: { _, _ in
                                   guard m.reviewRequests.indices.contains(n - 1) else { throw Refusal("no review request \(Verbs.askedLetters[n - 1])") }
                                   app.runner.dispatch("forests.review.open", via: .key, target: String(m.reviewRequests[n - 1].number))
                               }))
        }
        r.register(Command(id: "forests.pr.next", title: "Review the next open PR", scope: .global, verb: .nextOpenPR, label: "open PR",
                           pair: "forests.pr.prev", recordsJump: true, available: { _ in !m.openPRRows().isEmpty }, local: { _, _ in try hopPR(1) }))
        r.register(Command(id: "forests.pr.prev", title: "Review the previous open PR", scope: .global, verb: .previousOpenPR, label: "open PR",
                           recordsJump: true, available: { _ in !m.openPRRows().isEmpty }, local: { _, _ in try hopPR(-1) }))

        r.register(Command(
            id: "forest.branch.next", title: "Next branch in merge order", scope: .forest, verb: .nextSibling, label: "branch", pair: "forest.branch.prev",
            available: { _ in !mergeOrder(app).isEmpty },
            local: { _, _ in
                let order = mergeOrder(app)
                let at = order.firstIndex { $0.b.id == here(app)?.b.id }
                guard let next = at.map({ $0 + 1 }) ?? (order.isEmpty ? nil : 0), order.indices.contains(next) else {
                    throw Refusal("the last branch in merge order")
                }
                go(order[next], app)
            }))
        r.register(Command(
            id: "forest.branch.prev", title: "Previous branch in merge order", scope: .forest, verb: .previousSibling, label: "branch",
            available: { _ in !mergeOrder(app).isEmpty },
            local: { _, _ in
                let order = mergeOrder(app)
                let at = order.firstIndex { $0.b.id == here(app)?.b.id }
                guard let prev = at.map({ $0 - 1 }) ?? (order.isEmpty ? nil : order.count - 1), order.indices.contains(prev) else {
                    throw Refusal("the first branch in merge order")
                }
                go(order[prev], app)
            }))
        r.register(Command(
            id: "forest.parent", title: "Go to the branch's parent", scope: .forest, label: "parent", pair: "forest.child",
            recordsJump: true, available: onBranch,
            local: { _, _ in
                guard let v = here(app) else { return }
                guard let p = parent(of: v, app) else { throw Refusal("\(leaf(v.b.name)) sits on \(v.b.parent)") }
                go(p, app)
            }))
        r.register(Command(
            id: "forest.child", title: "Go to the branch's child (labels at a fork)", scope: .forest, label: "child",
            recordsJump: true, available: onBranch,
            local: { _, _ in
                guard let v = here(app) else { return }
                let kids = children(of: v.b.id, app)
                switch kids.count {
                case 0: throw Refusal("nothing builds on \(leaf(v.b.name))")
                case 1: go(kids[0], app)
                default:
                    // Graphite asks at a fork; here the label layer offers just the children
                    m.childChoice = kids.map { RowKey.branch($0.b.id) }
                    defer { m.childChoice = nil }
                    try app.showLabels()
                }
            }))
        r.register(Command(
            id: "forest.requires", title: "Go to a branch this one builds on — its parent, or a requires dep (which one, at a fan-in)",
            scope: .forest, label: "requires", recordsJump: true, available: onBranch,
            local: { _, _ in
                guard let v = here(app) else { return }
                ancestry.open(v.b)
            }))

        // Ancestry by name (NAV.md 2026-11-08: one next — merge order; ancestry is named, not stepped):
        // `:parent`, `:child`, `:requires` on whichever page is up.
        for (name, title) in [("parent", "Go to the branch's parent"), ("child", "Go to the branch's child (which one, at a fan-out)"),
                              ("requires", "Go to a branch this one builds on: its parent or a requires dep")] {
            r.register(Command(
                id: name, title: title, scope: .global, label: name,
                available: { _ in
                    let surface = app.router.surface.id
                    guard ["review", "forest"].contains(surface), let command = r.command("\(surface).\(name)") else { return false }
                    return command.available?(app.target(for: command.scope)) ?? true
                },
                route: { _ in
                    switch app.router.surface.id {
                    case "review": RouteTo("review.\(name)")
                    case "forest": RouteTo("forest.\(name)")
                    default: nil
                    }
                }))
            r.alias(["forest.\(name)", "review.\(name)"], to: name)
        }
        r.register(Command(
            id: "forest.root", title: "Go to the root of the branch's stack", scope: .forest, verb: .root, label: "root", pair: "forest.tip",
            available: onBranch,
            local: { _, _ in
                guard var v = here(app) else { return }
                var seen: Set<String> = [v.b.id]
                while let p = parent(of: v, app), seen.insert(p.b.id).inserted { v = p }
                go(v, app)
            }))
        r.register(Command(
            id: "forest.tip", title: "Go to the tip of the branch's stack", scope: .forest, verb: .tip, label: "tip",
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
            }))


        // ↵ on a PR awaiting review: the same import + route the Chrome extension's ⌘⇧U asks for
        struct Opened: Decodable { var ok: Bool; var path: String?; var err: String? }
        // a PR no forest carries opens through the server's /open-url: my own on its local branch, else fetched as review/pr-<N>
        func openOnGitHub(_ number: Int, _ url: String) {
            app.runner.say("opening #\(number)…")
            let t = app.transport
            Task { @MainActor in
                let got = await t.ask("/open-url", ["url": url, "open": "viewer"], as: Opened.self)
                guard let path = got?.path, got?.ok == true else {
                    return app.runner.say("couldn't open #\(number): \(got?.err ?? "the server didn't answer")")
                }
                app.open(address: path)
            }
        }
        r.register(Command(
            id: "forests.mypr.open", title: "Open one of my PRs no forest carries", scope: .forests, needsArg: true, label: "open",
            available: { m.myPR(RowKey.myPR(Int($0 ?? "") ?? -1)) != nil },
            local: { n, _ in
                guard let p = m.myPR(RowKey.myPR(Int(n ?? "") ?? -1)) else { return }
                openOnGitHub(p.number, p.url)
            }))
        r.register(Command(
            id: "forests.review.open", title: "Open a PR awaiting your review", scope: .forests, needsArg: true, label: "open",
            available: { m.reviewRequest(RowKey.reviewRequest(Int($0 ?? "") ?? -1)) != nil },
            local: { n, _ in
                guard let pr = m.reviewRequest(RowKey.reviewRequest(Int(n ?? "") ?? -1)) else { return }
                if !pr.imported { app.runner.say("fetching #\(pr.number)…") }
                let t = app.transport
                Task { @MainActor in
                    let got = await t.ask("/open-url", ["url": pr.url, "open": "viewer"], as: Opened.self)
                    guard let path = got?.path, got?.ok == true else {
                        return app.runner.say("couldn't open #\(pr.number): \(got?.err ?? "the server didn't answer")")
                    }
                    app.open(address: path)
                    await m.loadReviewRequests()
                }
            }))

        // space f: find on this page — forests (and open spines) on Forests, branches on a forest; picking moves the cursor
        func find(_ title: String) throws {
            let rows = app.rows
            guard !rows.isEmpty else { throw Refusal("nothing on this page to find") }
            let items = rows.map { row -> PickItem in
                if let id = RowKey.id(row, "b"), let v = m.branchView(id) { return PickItem(label: v.b.name, text: v.b.description) }
                if let id = RowKey.id(row, "p"), let p = app.store.view(Project.self, id) { return PickItem(label: p.name, text: p.summary) }
                if let r = m.reviewRequest(row) { return PickItem(label: "#\(r.number)", text: r.title) }
                if let v = m.openPR(row) { return PickItem(label: "#\(v.pr?.number ?? 0)", text: v.pr?.title ?? v.b.description) }
                if let p = m.myPR(row) { return PickItem(label: "#\(p.number)", text: p.title) }
                return PickItem(label: app.provider?.title(for: row, app) ?? row)
            }
            app.nav.pick(title, items) { i in app.jump { app.setCursor(rows[i]) } }
        }
        r.register(Command(
            id: "forests.find", title: "Find a forest on this page", scope: .forests, verb: .find, label: "find",
            local: { _, _ in try find("find a forest") }))
        r.register(Command(
            id: "forest.find", title: "Find a branch on this forest", scope: .forest, verb: .find, label: "find",
            local: { _, _ in try find("find a branch") }))
    }
}
