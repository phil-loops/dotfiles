import CanopyCore
import Foundation

/// The navigation pickers and slots (NAV.md §4.3), fed through the shared picker
/// (`app.nav.pick(title, items) { index in … }`) — area F owns how it looks.
extension AppModel {
    /// The forest you're in (a forest page, or the branch under review's forest), for the context boost.
    var currentForest: String? {
        if let p = router.route.projectID { return p }
        return router.route.branchID.flatMap { store.view(Branch.self, $0)?.project }
    }

    /// `space b`: every branch in every forest, the ones you visit most and most recently first,
    /// twice as strongly in the forest you're in; typing filters fuzzily.
    func pickBranch() throws {
        let here = currentForest
        let all = store.list(Branch.self)
        guard !all.isEmpty else { throw Refusal("no branches yet") }
        let boost: (Branch) -> Double = { $0.project == here ? 2 : 1 }
        let ordered = frecency.rank(all, "", id: \.id, text: \.name, boost: boost)
        let items = ordered.map { b in
            PickItem(label: b.name, text: "\(store.view(Project.self, b.project)?.name ?? b.project) · \(b.subject)")
        }
        let fr = frecency
        let rank: (String) -> [Int] = { want in
            fr.rank(Array(items.indices), want, id: { ordered[$0].id }, text: { "\(items[$0].label) \(items[$0].text ?? "")" }, boost: { boost(ordered[$0]) })
        }
        nav.pick("branches", items, rank: rank) { [weak self] i in
            let b = ordered[i]
            self?.go(.review(repo: b.repo, branch: b.name))
        }
    }

    /// One line describing a jumplist entry.
    func describe(_ p: Place) -> String {
        var s: String
        switch p.route {
        case .review(_, let b, let base): s = "review \(b)\(base.isEmpty ? "" : " vs \(base)")"
        case .forest(_, let pr): s = "forest \(pr)"
        default: s = p.route.surface.title.lowercased() + (p.arg.isEmpty ? "" : " \(p.arg)")
        }
        if let t = p.tab { s += " · \(t)" }
        if let l = p.loc { s += " · \(l.path):\(l.line)" } else if let k = p.cursorKey, let pre = k.split(separator: ":").first, ["p", "b", "t", "d", "m", "w", "c", "s"].contains(pre) {
            s += " · \(guessTitle(k))"
        }
        return s
    }

    /// `space j`: the jumplist as a picker, newest first; picking one is a jump.
    func pickJump() throws {
        let entries = jumps.entries
        guard !entries.isEmpty else { throw Refusal("the jumplist is empty") }
        nav.pick("jumplist", entries.map { PickItem(label: describe($0)) }) { [weak self] i in
            guard let self, let to = self.jumps.jump(to: i, from: self.here()) else { return }
            self.restore(to)
        }
    }

    /// The focus lane as the forests home shows it (rank, then name, then repo; shelved ones out): `g 1`…`g 9`.
    var focusLane: [Project] { forestModel.projects().focus }

    /// `g N`: the Nth focus forest, at the branch you last had open in it (else its page).
    func goSlot(_ n: Int) throws {
        let lane = focusLane
        guard lane.indices.contains(n - 1) else { throw Refusal("no focus forest \(n)") }
        let p = lane[n - 1]
        let mine = store.list(Branch.self).filter { $0.project == p.id }
        if let last = frecency.latest(mine.map(\.id)), let b = store.view(Branch.self, last) {
            go(.review(repo: b.repo, branch: b.name))
        } else {
            go(.forest(repo: p.repo, project: p.name))
        }
    }

    /// `/`: search the page's rows by their text; picking one moves the cursor there (a jump).
    func searchPage() throws {
        let rows = panes.flatMap { p in p.rows.map { (p.id, $0) } }
        guard !rows.isEmpty else { throw Refusal("nothing on this page to search") }
        let items = rows.map { PickItem(label: provider?.title(for: $0.1, self) ?? guessTitle($0.1), text: panes.count > 1 ? $0.0 : nil) }
        nav.pick("search this page", items) { [weak self] i in
            guard let self else { return }
            self.jump {
                self.focus(pane: rows[i].0)
                self.setCursor(rows[i].1)
            }
        }
    }
}

extension NavCommands {
    static func installPickers(_ app: AppModel) {
        let r = app.registry
        r.register(Command(id: "nav.branches", title: "Find a branch — every forest, most visited first", scope: .global, verb: .branches, label: "branches",
                           local: { [weak app] _, _ in try app?.pickBranch() }))
        r.register(Command(id: "nav.jumps", title: "Pick from the jumplist", scope: .global, verb: .jumps, label: "jumplist",
                           local: { [weak app] _, _ in try app?.pickJump() }))
        r.register(Command(id: "nav.picker.last", title: "Reopen the last picker, query and all", scope: .global, verb: .lastPicker, label: "last picker",
                           available: { [weak app] _ in app?.nav.canReopen ?? false },
                           local: { [weak app] _, _ in app?.nav.reopen() }))
        r.register(Command(id: "page.search", title: "Search this page", scope: .global, verb: .search, label: "search",
                           local: { [weak app] _, _ in try app?.searchPage() }))
        for n in 1...9 {
            r.register(Command(id: "nav.slot.\(n)", title: "Go to focus forest \(n) (where you left it)", scope: .global, verb: .slot(n),
                               quiet: n > 1, recordsJump: true,
                               local: { [weak app] _, _ in try app?.goSlot(n) }))
        }
    }
}
