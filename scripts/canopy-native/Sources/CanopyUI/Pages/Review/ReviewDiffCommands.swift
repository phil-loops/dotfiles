import CanopyCore
import Foundation

// The review page's diff commands (commands/review.ts, the diff half): moving by line, hunk, file,
// thread and branch; tabs, split, base; the map; folds and hidden lines; viewed; code navigation;
// open in Helix. Ship's half (comment, reply, send, resolve, history, …) is area C's.
@MainActor
enum DiffCommands {
    static let motion: [KeyMode] = [.normal, .select]

    static func install(_ app: AppModel) {
        let r = app.registry
        let pg = ReviewPageState.of(app)

        let onFiles: (String?) -> Bool = { [weak pg] _ in pg?.tab == "files" && app.keys.layer != .map }
        let onDiff: (String?) -> Bool = { [weak pg] _ in
            guard let pg else { return false }
            return (pg.tab == "files" || (pg.tab == "commits" && pg.scoped)) && app.keys.layer != .map
        }

        /// The diff cursor's index, and a move to one.
        func idx() -> Int { pg.here.flatMap { pg.stopIndex[$0.key] } ?? 0 }
        func goTo(_ i: Int) {
            let s = pg.stops
            guard !s.isEmpty else { return }
            pg.setCursor(s[max(0, min(s.count - 1, i))].key)
            CodeLookup.of(app).dismiss()
        }
        func seek(_ dir: Int, _ ok: (Stop) -> Bool) throws {
            let s = pg.stops
            var i = idx() + dir
            while i >= 0 && i < s.count {
                if ok(s[i]) { return goTo(i) }
                i += dir
            }
            throw Refusal(dir > 0 ? "nothing further down" : "nothing further up")
        }

        // ── moving ──

        r.register(Command(id: "review.down", title: "Next line", scope: .review, keys: ["j", "down"], modes: motion, label: "line", pair: "review.up", quiet: true,
                           local: { _, _ in
                               if app.keys.mode != .select { pg.mark = nil }
                               app.moveCursor(1)
                               pg.cursorMoved &+= 1
                               CodeLookup.of(app).dismiss()
                           }))
        r.register(Command(id: "review.up", title: "Previous line", scope: .review, keys: ["k", "up"], modes: motion, label: "line", quiet: true,
                           local: { _, _ in
                               if app.keys.mode != .select { pg.mark = nil }
                               app.moveCursor(-1)
                               pg.cursorMoved &+= 1
                               CodeLookup.of(app).dismiss()
                           }))
        r.register(Command(id: "review.top", title: "Go to the first line", scope: .review, keys: ["g g"], modes: motion, label: "ends", pair: "review.bottom", quiet: true,
                           local: { _, _ in app.cursorTo(0); pg.cursorMoved &+= 1; CodeLookup.of(app).dismiss() }))
        r.register(Command(id: "review.bottom", title: "Go to the last line", scope: .review, keys: ["G"], modes: motion, label: "ends", quiet: true,
                           local: { _, _ in app.cursorTo(Int.max); pg.cursorMoved &+= 1; CodeLookup.of(app).dismiss() }))
        r.register(Command(id: "review.hunk.next", title: "Go to the next hunk", scope: .review, keys: NavKeys.keys("review.hunk.next"), modes: motion,
                           label: "hunk", pair: "review.hunk.prev", available: onDiff, local: { _, _ in try hunk(1) }))
        r.register(Command(id: "review.hunk.prev", title: "Go to the previous hunk", scope: .review, keys: NavKeys.keys("review.hunk.prev"), modes: motion,
                           label: "hunk", available: onDiff, local: { _, _ in try hunk(-1) }))
        /// }/{: the first changed line of the next (previous) hunk — "a bigger j".
        func hunk(_ dir: Int) throws {
            let s = pg.stops
            let here = pg.here
            let cur = here.flatMap { h in h.row.map { "\(h.path)#\($0.hunk)" } ?? (h.kind == .gap ? "\(h.path)#\(h.at ?? -1)" : nil) }
            var i = idx() + dir
            var target: String?
            while i >= 0 && i < s.count {
                let st = s[i]
                if let row = st.row {
                    let h = "\(st.path)#\(row.hunk)"
                    if h != cur {
                        target = h
                        break
                    }
                }
                i += dir
            }
            guard let target else { throw Refusal(dir > 0 ? "no hunk further down" : "no hunk further up") }
            let rows = s.enumerated().filter { e in e.element.row.map { "\(e.element.path)#\($0.hunk)" == target } ?? false }
            let changed = rows.first { $0.element.row!.left?.kind != .ctx || $0.element.row!.right?.kind != .ctx } ?? rows.first!
            if app.keys.mode != .select { pg.mark = nil }
            goTo(changed.offset)
        }
        r.register(Command(id: "review.file.next", title: "Go to the next file", scope: .review, keys: NavKeys.keys("review.file.next"), modes: motion,
                           label: "file", pair: "review.file.prev", available: onDiff,
                           local: { _, _ in try seek(1) { $0.kind == .file } }))
        r.register(Command(id: "review.file.prev", title: "Go to the previous file", scope: .review, keys: NavKeys.keys("review.file.prev"), modes: motion,
                           label: "file", available: onDiff,
                           local: { _, _ in try seek(-1) { $0.kind == .file } }))
        /// n/N: open conversations first, then any.
        func thread(_ dir: Int) throws {
            func openOne(_ s: Stop) -> Bool {
                guard s.kind == .thread, let t = s.id.flatMap({ app.store.view(CanopyCore.Thread.self, $0) }) else { return false }
                return !t.resolved && !t.outdated
            }
            if (try? seek(dir, openOne)) != nil { return }
            try seek(dir) { $0.kind == .thread }
        }
        r.register(Command(id: "review.thread.next", title: "Go to the next conversation (open ones first)", scope: .review,
                           keys: NavKeys.keys("review.thread.next"), label: "thread", pair: "review.thread.prev", available: onDiff,
                           local: { _, _ in try thread(1) }))
        r.register(Command(id: "review.thread.prev", title: "Go to the previous conversation (open ones first)", scope: .review,
                           keys: NavKeys.keys("review.thread.prev"), label: "thread", available: onDiff,
                           local: { _, _ in try thread(-1) }))
        r.register(Command(id: "review.cursor.set", title: "Put the cursor here", scope: .review, needsArg: true, quiet: true,
                           local: { key, shift in
                               guard let key else { return }
                               let h = pg.here
                               if shift as? Bool == true, key.hasPrefix("l|"), h?.kind == .line { pg.mark = pg.mark ?? h?.key } else { pg.mark = nil }
                               pg.setCursor(key)
                               CodeLookup.of(app).dismiss()
                           }))
        r.register(Command(id: "review.file.go", title: "Go to a file", scope: .review, needsArg: true, quiet: true, recordsJump: true,
                           local: { _, arg in
                               pg.tab = "files"
                               if let path = arg as? String {
                                   if pg.fileOf(path)?.viewed == false, let first = pg.stops.first(where: { $0.path == path && $0.kind == .line }) {
                                       pg.setCursor(first.key)
                                   } else {
                                       pg.setCursor("f|\(path)")
                                   }
                               }
                           }))
        r.register(Command(id: "review.in", title: "Into the diff at the file", scope: .review, keys: ["l"], label: "in",
                           available: { _ in app.pane?.id == reviewTreePane && onFiles(nil) },
                           route: { _ in
                               guard let row = app.selected, row.hasPrefix("f|") else { return nil }
                               return RouteTo("review.file.go", arg: String(row.dropFirst(2)))
                           }))
        r.register(Command(id: "review.extend", title: "Extend the selection a line (comment on a range)", scope: .line, keys: ["x"], label: "range",
                           local: { _, _ in
                               guard let h = pg.here, h.kind == .line else { return }
                               guard pg.mark != nil else { pg.mark = h.key; return }
                               let s = pg.stops
                               var i = idx() + 1
                               while i < s.count && s[i].path == h.path {
                                   if s[i].kind == .line { return pg.setCursor(s[i].key) }
                                   i += 1
                               }
                           }))

        // ── J/K and the DAG: hop to another branch's review, same tab, same file if it's touched ──

        func hop(_ b: Branch?) throws {
            guard let b else { throw Refusal("no branch that way") }
            pg.carry = (b.id, pg.tab, pg.here?.path)
            app.go(.review(repo: b.repo, branch: b.name, base: pg.base == .outgoing ? "" : pg.base.rawValue))
        }
        let isBranch: (String?) -> Bool = { _ in pg.integration == nil && pg.branch != nil }
        r.register(Command(id: "review.branch.next", title: "Review the next branch in merge order", scope: .review, keys: NavKeys.keys("review.branch.next"),
                           label: "branch", pair: "review.branch.prev", available: isBranch, local: { _, _ in try hop(pg.neighbour(1)) }))
        r.register(Command(id: "review.branch.prev", title: "Review the previous branch in merge order", scope: .review, keys: NavKeys.keys("review.branch.prev"),
                           label: "branch", available: isBranch, local: { _, _ in try hop(pg.neighbour(-1)) }))
        func children(_ id: String) -> [Branch] {
            app.store.list(Branch.self).filter { $0.parentId == id }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        }
        /// A fan-out asks which child (Graphite's `up`): the picker, one line per child.
        func pickChild(_ kids: [Branch], then: @escaping @MainActor (Branch) -> Void) {
            app.nav.pick("which child · \(kids.count)", kids.map { PickItem(label: $0.name, text: $0.description) }) { i in
                MainActor.assumeIsolated { then(kids[i]) }
            }
        }
        r.register(Command(id: "review.parent", title: "Review its parent branch", scope: .review, keys: NavKeys.keys("review.parent"), label: "parent",
                           available: isBranch, local: { _, _ in try hop(pg.branch?.parentId.flatMap { app.store.view(Branch.self, $0) }) }))
        r.register(Command(id: "review.child", title: "Review a child branch (which one, at a fan-out)", scope: .review, keys: NavKeys.keys("review.child"),
                           label: "child", available: isBranch,
                           local: { _, _ in
                               let kids = children(pg.id)
                               if kids.count > 1 { return pickChild(kids) { b in MainActor.assumeIsolated { _ = try? hop(b) } } }
                               try hop(kids.first)
                           }))
        r.register(Command(id: "review.root", title: "Review the stack's root", scope: .review, keys: NavKeys.keys("review.root"), label: "root",
                           available: isBranch,
                           local: { _, _ in
                               var b = pg.branch
                               var n = 0
                               while let p = b?.parentId.flatMap({ app.store.view(Branch.self, $0) }), n < 64 { b = p; n += 1 }
                               if b?.id == pg.id { throw Refusal("this is the root") }
                               try hop(b)
                           }))
        r.register(Command(id: "review.tip", title: "Review the stack's tip (which one, at a fan-out)", scope: .review, keys: NavKeys.keys("review.tip"), label: "tip",
                           available: isBranch,
                           local: { _, _ in
                               @MainActor func down(_ b: Branch, _ n: Int) {
                                   let kids = children(b.id)
                                   if kids.isEmpty || n > 64 { if b.id != pg.id { try? hop(b) } else { app.runner.say("this is the tip") }; return }
                                   if kids.count == 1 { return down(kids[0], n + 1) }
                                   pickChild(kids) { k in MainActor.assumeIsolated { down(k, n + 1) } }
                               }
                               guard let b = pg.branch else { return }
                               down(b, 0)
                           }))

        // ── the page ──

        let tabs = ["conversation", "commits", "files"]
        r.register(Command(id: "review.tab", title: "Cycle the tabs", scope: .review, keys: ["tab"], label: "tab",
                           local: { _, _ in pg.tab = tabs[((tabs.firstIndex(of: pg.tab) ?? 2) + 1) % tabs.count] }))
        for (i, t) in tabs.enumerated() {
            r.register(Command(id: "review.tab.\(t)", title: "Show the \(t) tab", scope: .review, keys: ["\(i + 1)"], label: t,
                               local: { _, _ in pg.tab = t }))
        }
        r.register(Command(id: "review.split", title: "Switch between split and unified diff", scope: .review, keys: ["space s"], label: "split",
                           local: { _, _ in pg.split.toggle() }))
        r.register(Command(id: "review.outdated", title: "Show or hide outdated conversations", scope: .review, keys: ["space o"], label: "outdated",
                           local: { _, _ in pg.showOutdated.toggle() }))

        func baseOK(_ b: ReviewBase) -> Bool { pg.integration == nil && (b != .outgoing || (pg.branch != nil && pg.branch?.pushed != .local)) }
        for (b, k, title) in [(ReviewBase.parent, "p", "Diff against its parent — this branch's own change, what the PR shows"),
                              (.main, "m", "Diff against main — the whole stack up to here, as it would land"),
                              (.outgoing, "o", "Diff against origin — what the next push sends")] {
            r.register(Command(id: "review.base.\(b.word)", title: title, scope: .review, keys: ["space d \(k)"], label: b.word,
                               available: { _ in baseOK(b) },
                               local: { _, _ in pg.tab = "files"; pg.setBase(b) }))
        }
        r.register(Command(id: "review.base.next", title: "Diff against the next base", scope: .review, quiet: true,
                           available: { _ in pg.integration == nil },
                           local: { _, _ in
                               let ok = ReviewBase.allCases.filter(baseOK)
                               let at = ok.firstIndex(of: pg.base) ?? -1
                               pg.setBase(ok[(at + 1) % ok.count])
                           }))
        r.register(Command(id: "review.filter", title: "Find a file (filter the tree)", scope: .review, keys: NavKeys.keys("review.filter"), label: "find",
                           local: { _, _ in
                               pg.tab = "files"
                               app.focus(pane: reviewTreePane)
                               app.beginInsert(ReviewPage.filterField)
                           }))
        r.register(Command(id: "review.filter.accept", title: "Go to the first file the filter finds", scope: .review, keys: ["ret"], modes: [.insert], quiet: true,
                           available: { _ in app.insertField == ReviewPage.filterField },
                           local: { _, _ in
                               app.keys.setMode(.normal)
                               guard let first = ReviewPage.treeRows(pg).first else { throw Refusal("no file matches") }
                               app.runner.dispatch("review.file.go", via: .key, arg: String(first.dropFirst(2)))
                           }))

        // ── the map (space m): a layer with its own keys ──

        r.register(Command(id: "review.map", title: "Show the forest map", scope: .review, keys: ["space m"], label: "map",
                           local: { _, _ in
                               if app.keys.layer == .map { return app.keys.closeLayer() }
                               pg.mapIndex = max(0, ReviewMap.rows(app).firstIndex { $0.id == pg.id } ?? 0)
                               app.keys.openLayer(.map)
                           }))
        r.register(Command(id: "review.map.down", title: "Next branch on the map", scope: .review, keys: ["j", "down"], modes: [.map], quiet: true,
                           local: { _, _ in pg.mapIndex = min(max(0, ReviewMap.rows(app).count - 1), pg.mapIndex + 1) }))
        r.register(Command(id: "review.map.up", title: "Previous branch on the map", scope: .review, keys: ["k", "up"], modes: [.map], quiet: true,
                           local: { _, _ in pg.mapIndex = max(0, pg.mapIndex - 1) }))
        r.register(Command(id: "review.map.open", title: "Open the branch under the map's cursor", scope: .review, keys: ["ret", "l"], modes: [.map], quiet: true,
                           route: { _ in
                               let rows = ReviewMap.rows(app)
                               return rows.indices.contains(pg.mapIndex) ? RouteTo("review.map.go", arg: rows[pg.mapIndex].id) : nil
                           }))
        r.register(Command(id: "review.map.page", title: "Go to the forest's page", scope: .review, keys: ["p", "h"], modes: [.map], quiet: true,
                           local: { _, _ in app.keys.closeLayer(); app.runner.dispatch("review.leave", via: .key) }))
        r.register(Command(id: "review.map.go", title: "Open a branch from the map", scope: .review, needsArg: true, quiet: true,
                           local: { _, arg in
                               if app.keys.layer == .map { app.keys.closeLayer() }
                               guard let id = arg as? String, let cut = id.firstIndex(of: ":") else { return }
                               app.go(.review(repo: String(id[..<cut]), branch: String(id[id.index(after: cut)...])))
                           }))

        // ── hidden lines ──

        r.register(Command(id: "review.expand", title: "Show 20 more hidden lines", scope: .gap, keys: ["ret"], label: "more",
                           available: { $0?.hasPrefix("g|") ?? false },
                           local: { key, _ in
                               guard let key, let cut = key.lastIndex(of: "|"), let at = Int(key[key.index(after: cut)...]) else { return }
                               let path = String(key[key.index(key.startIndex, offsetBy: 2)..<cut])
                               Task { @MainActor in
                                   await pg.reveal(path, at: at)
                                   // a gap that just closed takes the cursor to the line it ended on, not back to the top
                                   guard let fv = pg.fileOf(path), !fv.gaps.contains(where: { $0.at == at }), !fv.file.hunks.isEmpty else { return }
                                   let end = at < fv.file.hunks.count ? fv.file.hunks[at].lines.first : fv.file.hunks[fv.file.hunks.count - 1].lines.last
                                   if let end { pg.setCursor("l|\(path)|\(end.new != nil ? "R:\(end.new!)" : "L:\(end.old ?? 0)")") }
                               }
                           }))

        // ── out, and back out ──

        r.register(Command(id: "review.leave", title: "Go back to its forest", scope: .review, keys: ["h"], label: "back",
                           available: { _ in app.pane?.id != reviewCodePane || pg.side == nil },
                           local: { _, _ in
                               let pid = pg.branch?.project ?? pg.integration
                               guard let pid, let p = app.store.view(Project.self, pid) else { return app.go(.forests) }
                               let id = pg.id
                               app.go(.forest(repo: p.repo, project: p.name))
                               if pg.integration == nil { app.setCursor(RowKey.branch(id)) }
                           }))
        r.register(Command(id: "review.back", title: "Back out", scope: .review, keys: ["esc"], label: "back", quiet: true,
                           local: { _, _ in
                               if ShipSeam.backOut(app) { return }
                               let look = CodeLookup.of(app)
                               if look.pop != nil { return look.dismiss() }
                               if app.nav.picker != nil { return app.nav.close() }
                               if pg.side != nil { return pg.closeSide() }
                               if !pg.filter.isEmpty { pg.filter = ""; return }
                               if pg.mark != nil { pg.mark = nil; return }
                               throw Refusal(KeyEngine.nothingToCancel)
                           }))

        // ── code navigation ──

        func position() -> (CodeLookup.Position?, CodeLookup.Where?) {
            guard let t = pg.target else { return (nil, nil) }
            if let s = pg.side, app.pane?.id == reviewCodePane {
                let n = RowKey.id(app.selected, "s").flatMap(Int.init) ?? s.line
                let lines = (pg.sideText ?? "").components(separatedBy: "\n")
                let text = n >= 1 && n <= lines.count ? lines[n - 1] : ""
                return (CodeLookup.position(path: s.path, line: n, text: text), .commit(repo: s.repo, sha: s.sha))
            }
            let w = CodeLookup.Where.branch(repo: t.repo, name: t.name, base: pg.baseSha)
            if let p = pg.pointer, p.seq == pg.cursorMoved, p.key == pg.here?.key {
                if pg.scoped, let sha = pg.commitScope { return (p.pos, .commit(repo: t.repo, sha: sha)) }
                return (p.pos, w)
            }
            guard let h = pg.here, h.kind == .line, let row = h.row else { return (nil, w) }
            let old = row.right == nil
            let l = (row.right ?? row.left)!
            let pos = CodeLookup.position(path: h.path, line: (old ? l.old : l.new) ?? 1, text: l.text, side: old ? "old" : "new")
            if pg.scoped, let sha = pg.commitScope { return (pos, .commit(repo: t.repo, sha: sha)) }
            return (pos, w)
        }
        let codeOK: (String?) -> Bool = { _ in onFiles(nil) || app.pane?.id == reviewCodePane || pg.scoped }
        r.register(Command(id: "review.types", title: "Show the type (hover)", scope: .review, keys: ["space k"], label: "type", available: codeOK,
                           local: { _, _ in let (p, w) = position(); CodeLookup.of(app).hover(p, w) }))
        for (id, kind, key, title, label) in [("review.definition", LSPGoto.definition, "g d", "Go to the definition — in the diff when it's there, else beside it", "def"),
                                              ("review.type-definition", .typeDefinition, "g y", "Go to the definition of its type", "type def"),
                                              ("review.implementation", .implementation, "g I", "Go to its implementations", "impl"),
                                              ("review.references", .references, "g r", "List its references", "refs")] {
            r.register(Command(id: id, title: title, scope: .review, keys: [key], label: label, available: codeOK,
                               local: { _, _ in let (p, w) = position(); CodeLookup.of(app).goto(kind, p, w) }))
        }
        r.register(Command(id: "review.symbols", title: "List the file's symbols", scope: .review, keys: ["space S"], label: "symbols", available: codeOK,
                           local: { _, _ in
                               let (p, w) = position()
                               let path = p?.path ?? (app.pane?.id == reviewCodePane ? pg.side?.path : pg.here?.path)
                               CodeLookup.of(app).symbols(path: path, side: p?.side ?? "new", w)
                           }))
        r.register(Command(id: "review.side.close", title: "Close the code beside the diff", scope: .review, quiet: true,
                           available: { _ in pg.side != nil }, local: { _, _ in pg.closeSide() }))

        r.register(Command(id: "review.open", title: "Open in Helix", scope: .review, budget: .slowIO, keys: ["o"], label: "helix",
                           available: { _ in pg.integration == nil },
                           write: { _, _ in openHere(pg) }))

        // ── viewed: m marks and moves on, M takes it back ──

        r.register(Command(id: "review.viewed", title: "Mark viewed and go on to the next unviewed — the hunk, the file on its header, the range in select",
                           scope: .review, budget: .configWrite, keys: NavKeys.keys("review.viewed"), modes: motion, label: "viewed", pair: "review.unviewed",
                           available: { _ in onDiff(nil) && pg.here != nil && !pg.scoped },
                           write: { _, _ in
                               let w = viewed(app, pg, on: true)
                               if app.keys.mode == .select { app.keys.setMode(.normal) }
                               return w
                           }))
        r.register(Command(id: "review.unviewed", title: "Mark unviewed — the hunk, the file on its header, the range in select",
                           scope: .review, budget: .configWrite, keys: NavKeys.keys("review.unviewed"), modes: motion, label: "unviewed",
                           available: { _ in onDiff(nil) && pg.here != nil && !pg.scoped },
                           write: { _, _ in
                               let w = viewed(app, pg, on: false)
                               if app.keys.mode == .select { app.keys.setMode(.normal) }
                               return w
                           }))
        r.register(Command(id: "review.viewed.file", title: "Mark a file viewed (or not)", scope: .review, budget: .configWrite, needsArg: true, quiet: true,
                           write: { _, arg in
                               guard let path = arg as? String, let fv = pg.fileOf(path) else { return nil }
                               let on = !fv.blocks.allSatisfy { pg.isSeen($0.key) }
                               if on { advance(pg, from: path, hunk: nil) }
                               return viewedSet(app, pg, fv.blocks.map(\.key), on: on)
                           }))
        r.register(Command(id: "review.viewed.set", title: "Put viewed marks back", scope: .review, budget: .configWrite, needsArg: true, quiet: true,
                           write: { _, arg in
                               guard let a = arg as? ViewedArg else { return nil }
                               return viewedSet(app, pg, a.keys, on: a.on)
                           }))

        // ── the commits tab's inline diffs (InlineDiff.tsx, inline.ts) ──

        r.register(Command(id: "inline.expand", title: "Show 20 more lines around a commit's change", scope: .review, needsArg: true, quiet: true,
                           local: { t, arg in
                               let s = (arg as? String) ?? t ?? ""
                               let parts = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                               guard parts.count >= 3, let at = Int(parts.last!) else { return }
                               InlineDiffs.of(app).revealAt(sha: parts[0], path: parts[1..<(parts.count - 1)].joined(separator: "|"), at: at)
                           }))
        r.register(Command(id: "inline.fold", title: "Fold or unfold a commit's diff", scope: .review, needsArg: true, quiet: true,
                           local: { t, arg in
                               let parts = ((arg as? String) ?? t ?? "").split(separator: " ").map(String.init)
                               guard parts.count == 2, let n = Int(parts[1]) else { return }
                               InlineDiffs.of(app).toggleFold(parts[0], changed: n)
                           }))
    }

    /// Open what the cursor is on in the warm Helix, at its line (POST /open).
    static func openHere(_ pg: ReviewPageState) -> Write? {
        guard let h = pg.here, h.kind != .file, let t = pg.target, let app = pg.app else { return nil }
        var line: JSONValue = .null
        if h.kind == .line, let row = h.row { line = .number(Double(sideLine(row).line)) }
        else if h.kind == .thread, let l = h.id.flatMap({ app.store.view(CanopyCore.Thread.self, $0) })?.local?.line { line = .number(Double(l)) }
        return Write(path: pg.repoPath("/open"), body: ["branch": .string(t.name), "path": .string(h.path), "line": line],
                     settled: { true }, failed: "couldn't open it in Helix")
    }

    struct ViewedArg { var keys: [String]; var on: Bool }

    /// Set change blocks viewed or not (POST /viewed): shown at once, rolled back if refused.
    static func viewedSet(_ app: AppModel, _ pg: ReviewPageState, _ keys: [String], on: Bool, said: String? = nil) -> Write? {
        guard !keys.isEmpty, let t = pg.target else { return nil }
        let was = pg.viewedOverride
        for k in keys { pg.viewedOverride[k] = on }
        return Write(path: pg.repoPath("/viewed"), body: ["branch": .string(t.name), "keys": .array(keys.map(JSONValue.string)), "on": .bool(on)],
                     settled: { keys.allSatisfy { pg.serverViewed.contains($0) == on } },
                     said: said, failed: "couldn't mark it \(on ? "viewed" : "unviewed")",
                     inverse: { _ in Inverse(id: "review.viewed.set", target: pg.id, arg: ViewedArg(keys: keys, on: !on)) },
                     rollback: { pg.viewedOverride = was })
    }

    /// What m / M act on: the select range's hunks, else the hunk under the cursor, else (a file
    /// header, a conversation, the lines past the last hunk) the whole file.
    static func viewedTargets(_ app: AppModel, _ pg: ReviewPageState) -> [(path: String, hunk: Int?)] {
        func of(_ s: Stop) -> (path: String, hunk: Int?) {
            let hunks = pg.fileOf(s.path)?.file.hunks.count ?? 0
            if let row = s.row { return (s.path, row.hunk) }
            if s.kind == .gap, let at = s.at, at < hunks { return (s.path, at) }
            return (s.path, nil)
        }
        if app.keys.mode == .select, app.pane?.id == reviewDiffPane {
            var out: [(path: String, hunk: Int?)] = []
            for k in app.selection {
                guard let i = pg.stopIndex[k] else { continue }
                let t = of(pg.stops[i])
                if !out.contains(where: { $0.path == t.path && $0.hunk == t.hunk }) { out.append(t) }
            }
            return out
        }
        return pg.here.map { [of($0)] } ?? []
    }

    static func viewed(_ app: AppModel, _ pg: ReviewPageState, on: Bool) -> Write? {
        let targets = viewedTargets(app, pg)
        var keys: [String] = []
        for t in targets {
            guard let fv = pg.fileOf(t.path) else { continue }
            keys += fv.blocks.filter { t.hunk == nil || $0.hunk == t.hunk }.map(\.key)
        }
        let todo = keys.filter { pg.isSeen($0) != on }
        if on, let last = targets.last { advance(pg, from: last.path, hunk: last.hunk) }
        guard !todo.isEmpty else {
            if !on { app.runner.say("not viewed yet") }
            return nil
        }
        let one = targets.count == 1 ? targets[0] : nil
        let whole = one.map { t in t.hunk == nil || todo.count == pg.fileOf(t.path)?.blocks.count } ?? false
        let said = one == nil ? "\(on ? "viewed" : "unviewed") \(targets.count) hunks — u puts them back"
            : whole ? nil : "\(on ? "viewed" : "unviewed") a hunk of \(shortPath(one!.path)) — u puts it back"
        return viewedSet(app, pg, todo, on: on, said: said)
    }

    /// On to the next thing still to read: the next unviewed hunk in this file, else the next unviewed file.
    static func advance(_ pg: ReviewPageState, from path: String, hunk: Int?) {
        guard let fv = pg.fileOf(path) else { return }
        if let hunk {
            let next = fv.file.hunks.indices.first { i in i > hunk && !fv.seenHunks.contains(i) && fv.blocks.contains { $0.hunk == i } }
            if let next, let row = fv.rows.first(where: { $0.hunk == next && ($0.left?.kind != .ctx || $0.right?.kind != .ctx) }) {
                return pg.setCursor("l|\(path)|\(row.key)")
            }
        }
        let vs = pg.views
        let at = vs.firstIndex { $0.file.path == path } ?? -1
        let after = vs[(at + 1)...].first { !$0.viewed }
        pg.setCursor("f|\(after?.file.path ?? path)")
    }
}
