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

    /// `space b`: every branch in every forest not archived, the ones you visit most and most
    /// recently first, twice as strongly in the forest you're in; typing filters fuzzily.
    func pickBranch() throws {
        let here = currentForest
        let all = store.list(Branch.self).filter { store.view(Project.self, $0.project)?.state != .archive }
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

    /// `space !`: every change flagged with `, !` in this repo, the branch you're on first, then newest
    /// first; picking one opens its branch with the cursor on the change.
    func pickFlags() throws {
        let repo = router.route.branchID.flatMap { store.view(Branch.self, $0)?.repo } ?? currentForest.flatMap { store.view(Project.self, $0)?.repo }
        let here = router.route.branchID
        let all = store.list(Viewed.self)
            .filter { repo == nil || $0.repo == repo }
            .flatMap { v in (v.flags ?? []).map { (v, $0) } }
            .sorted { a, b in
                let (ah, bh) = (a.0.id == here, b.0.id == here)
                return ah != bh ? ah : a.1.at > b.1.at
            }
        guard !all.isEmpty else { throw Refusal("nothing flagged · , ! flags a change") }
        let items = all.map { v, f in
            PickItem(label: "\(v.branch)  \(f.path.isEmpty ? "?" : "\(shortPath(f.path)):\(f.line)")", text: f.text.isEmpty ? f.path : f.text)
        }
        nav.pick("flagged", items) { [weak self] i in
            guard let self else { return }
            let (v, f) = all[i]
            self.recordJump()
            self.go(.review(repo: v.repo, branch: v.branch))
            ReviewPageState.of(self).land(flag: f)
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
    func searchPage(backward: Bool = false) throws {
        guard pane != nil, !panes.isEmpty else { throw Refusal("nothing on this page to search") }
        PageSearch.of(self).start(self, backward: backward)
    }
}

extension NavCommands {
    static func installPickers(_ app: AppModel) {
        KeyMode.textEntry.insert(.search)
        app.keys.layerTyping[.search] = { [weak app] k in app.map { PageSearch.of($0).type(k, $0) } ?? false }
        let r = app.registry
        r.register(Command(id: "nav.branches", title: "Find a branch — every forest, most visited first", scope: .global, verb: .branches, label: "branches",
                           local: { [weak app] _, _ in try app?.pickBranch() }))
        r.register(Command(id: "nav.jumps", title: "Pick from the jumplist", scope: .global, verb: .jumps, label: "jumplist",
                           local: { [weak app] _, _ in try app?.pickJump() }))
        r.register(Command(id: "nav.flags", title: "Pick a change you flagged, on any branch of this repo", scope: .global, verb: .flags, label: "flagged",
                           local: { [weak app] _, _ in try app?.pickFlags() }))
        r.register(Command(id: "nav.picker.last", title: "Reopen the last picker, query and all", scope: .global, verb: .lastPicker, label: "last picker",
                           available: { [weak app] _ in app?.nav.canReopen ?? false },
                           local: { [weak app] _, _ in app?.nav.reopen() }))
        r.register(Command(id: "page.search", title: "Search this page in place", scope: .global, verb: .search, label: "search",
                           local: { [weak app] _, _ in try app?.searchPage() }))
        r.register(Command(id: "page.search.back", title: "Search this page backwards", scope: .global, verb: .searchBack, label: "search back",
                           local: { [weak app] _, _ in try app?.searchPage(backward: true) }))
        let typing: (String?) -> Bool = { [weak app] _ in app.map { PageSearch.of($0).typing } ?? false }
        r.register(Command(id: "page.search.keep", title: "Keep the search (n / N step its matches)", scope: .global, verb: .send, modes: [.search], label: "keep", quiet: true,
                           available: typing, local: { [weak app] _, _ in app.map { PageSearch.of($0).keep($0) } }))
        r.register(Command(id: "page.search.cancel", title: "Drop the search, back where it began", scope: .global, verb: .cancel, modes: [.search], quiet: true,
                           available: typing, local: { [weak app] _, _ in app.map { PageSearch.of($0).cancel($0) } }))
        /// n / N: only ever the search's matches, as in Helix.
        func stepSearch(_ app: AppModel, _ d: Int) throws {
            let search = PageSearch.of(app)
            guard search.active && !search.typing else { throw Refusal("no search · / or ? searches") }
            if !search.step(app, d) { throw Refusal("no matches") }
        }
        r.register(Command(id: "page.search.next", title: "The next match", scope: .global, verb: .nextThread, quiet: true,
                           local: { [weak app] _, _ in try app.map { try stepSearch($0, 1) } }))
        r.register(Command(id: "page.search.prev", title: "The previous match", scope: .global, verb: .previousThread, quiet: true,
                           local: { [weak app] _, _ in try app.map { try stepSearch($0, -1) } }))
        app.addCloser(first: true, isOpen: { [weak app] in app.map { PageSearch.of($0).active } ?? false },
                      close: { [weak app] in app.map { PageSearch.of($0).clear() } })
        for n in 1...9 {
            r.register(Command(id: "nav.slot.\(n)", title: "Go to focus forest \(n) (where you left it)", scope: .global, verb: .slot(n),
                               quiet: n > 1, recordsJump: true,
                               local: { [weak app] _, _ in try app?.goSlot(n) }))
        }
    }
}
