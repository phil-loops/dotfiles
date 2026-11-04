import CanopyCore
import Foundation

/// The layer f / t wait in for the character to find.
let findCharLayer: KeyMode = "find-char"

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

        /// A line stop's text on one half: the old half only where it differs, and only as far as it's drawn.
        func halfText(_ s: Stop, _ side: Side) -> String? {
            guard s.kind == .line, let row = s.row else { return nil }
            if side == .right { return row.right?.new != nil ? row.right?.text : nil }
            guard row.left?.kind == .del, let t = row.left?.text as NSString? else { return nil }
            return t.substring(to: min(t.length, max(0, pg.splitWidth(s.path) - 1)))
        }
        func firstNonBlank(_ t: String) -> Int {
            let u = Array(t.utf16)
            return u.firstIndex { $0 != 32 && $0 != 9 } ?? 0
        }
        /// The whole character (an emoji, a letter and its accent) at a UTF-16 offset.
        func char(_ t: String, _ at: Int) -> Range<Int> {
            let r = (t as NSString).rangeOfComposedCharacterSequence(at: at)
            return r.location..<(r.location + r.length)
        }
        /// The character a step from `w` lands on, or nil past the line's edge.
        func stepped(_ t: String, from w: Range<Int>?, _ d: Int) -> Range<Int>? {
            let n = (t as NSString).length
            guard n > 0 else { return nil }
            guard let w else { return char(t, min(firstNonBlank(t), n - 1)) }
            let at = d > 0 ? w.upperBound : w.lowerBound - 1
            return at >= 0 && at < n ? char(t, at) : nil
        }
        /// The column j / k aim for, and the one last put down: a line too short for the goal puts the
        /// cursor at its end, and the next line aims for the goal again (vim's curswant). `carried` is
        /// the row the goal was last carried to, so a row with no code (a header, a conversation)
        /// passes the goal on instead of dropping it.
        var goal: Int?
        var placed: Int?
        var carried: String?
        func charStep(_ d: Int) throws {
            guard let h = pg.here, h.kind == .line, let row = h.row else { throw Refusal("no code on this row") }
            let side = sideLine(row, prefer: pg.column).side
            let t = halfText(h, side) ?? ""
            if let r = stepped(t, from: pg.hereWord, d) {
                pg.word = (h.key, side, r)
                (goal, placed, carried) = (r.lowerBound, r.lowerBound, h.key)
                pg.cursorMoved &+= 1
                return
            }
            let other: Side = side == .left ? .right : .left
            if (d < 0) == (side == .right), let o = halfText(h, other), !o.isEmpty {
                let r = d < 0 ? char(o, (o as NSString).length - 1) : char(o, firstNonBlank(o))
                pg.column = other
                pg.word = (h.key, other, r)
                (goal, placed, carried) = (r.lowerBound, r.lowerBound, h.key)
                pg.cursorMoved &+= 1
                return
            }
            throw Refusal(d < 0 ? "start of the line" : "end of the line")
        }
        /// After j / k: the character cursor at the same column on the new line, as far as it reaches.
        func keepColumn(from: Int?, was: String?) {
            let c: Int
            if let from { c = from == placed ? goal ?? from : from }
            else if let g = goal, was != nil, was == carried { c = g }
            else { (goal, placed, carried) = (nil, nil, nil); return }
            goal = c
            guard let h = pg.here else { return }
            carried = h.key
            guard let row = h.row else { return }
            let side = sideLine(row, prefer: pg.column).side
            let t = halfText(h, side) ?? ""
            let n = (t as NSString).length
            guard n > 0 else { return }
            let r = char(t, min(c, n - 1))
            pg.word = (h.key, side, r)
            placed = r.lowerBound
        }

        // ── moving ──

        /// gg / G: the first changed line of the diff, the last changed line of it.
        func ends(first: Bool) throws {
            if app.pane?.id != reviewDiffPane {
                let was = app.selected
                app.cursorTo(first ? 0 : Int.max)
                if app.selected == was { throw Refusal(first ? "already at the top" : "already at the bottom") }
                return
            }
            let s = pg.stops
            let target: Stop? = first
                ? pg.stopFiles.first.flatMap(pg.landing(file:)).flatMap { k in pg.stopIndex[k].map { s[$0] } }
                : s.last { $0.row.map(changed) ?? false } ?? s.last { $0.kind == .line }
            guard let target else { throw Refusal("nothing in this diff") }
            if target.key == pg.here?.key { throw Refusal(first ? "already at the first change" : "already at the last change") }
            if app.keys.mode != .select { pg.mark = nil }
            pg.setCursor(target.key)
            CodeLookup.of(app).dismiss()
        }
        /// ]/[: the next (previous) file by the diff's order, landing on its first change.
        func file(_ dir: Int) throws {
            let fs = pg.stopFiles
            guard let here = pg.here?.path, let i = fs.firstIndex(of: here) else { throw Refusal("no file here") }
            let j = i + dir
            guard fs.indices.contains(j), let k = pg.landing(file: fs[j]) else {
                let edge = fs.count <= 1 ? "the only file in this diff" : dir > 0 ? "the last file" : "the first file"
                throw Refusal("\(edge) · ] g [ g move by change")
            }
            if app.keys.mode != .select { pg.mark = nil }
            pg.setCursor(k)
            CodeLookup.of(app).dismiss()
        }

        r.register(Command(id: "review.down", title: "Next line", scope: .review, verb: .next, modes: motion, label: "line", pair: "review.up", quiet: true,
                           local: { _, _ in
                               if app.keys.mode != .select { pg.mark = nil }
                               let from = pg.hereWord?.lowerBound
                               let was = app.selected
                               let wasKey = pg.here?.key
                               app.moveCursor(1)
                               if app.selected == was { throw Refusal("nothing further down") }
                               if app.pane?.id == reviewDiffPane { keepColumn(from: from, was: wasKey) }
                               pg.cursorMoved &+= 1
                               CodeLookup.of(app).dismiss()
                           }))
        r.register(Command(id: "review.up", title: "Previous line", scope: .review, verb: .previous, modes: motion, label: "line", quiet: true,
                           local: { _, _ in
                               if app.keys.mode != .select { pg.mark = nil }
                               let from = pg.hereWord?.lowerBound
                               let was = app.selected
                               let wasKey = pg.here?.key
                               app.moveCursor(-1)
                               if app.selected == was { throw Refusal("nothing further up") }
                               if app.pane?.id == reviewDiffPane { keepColumn(from: from, was: wasKey) }
                               pg.cursorMoved &+= 1
                               CodeLookup.of(app).dismiss()
                           }))
        r.register(Command(id: "review.top", title: "Go to the first line", scope: .review, verb: .first, modes: motion, label: "ends", pair: "review.bottom", quiet: true,
                           local: { _, _ in try ends(first: true) }))
        r.register(Command(id: "review.bottom", title: "Go to the last line", scope: .review, verb: .last, modes: motion, label: "ends", quiet: true,
                           local: { _, _ in try ends(first: false) }))
        r.register(Command(id: "review.hunk.next", title: "Go to the next change", scope: .review, verb: .nextHunk, modes: motion,
                           label: "change", pair: "review.hunk.prev", available: onDiff, local: { _, _ in try change(1) }))
        r.register(Command(id: "review.hunk.prev", title: "Go to the previous change", scope: .review, verb: .previousHunk, modes: motion,
                           label: "change", available: onDiff, local: { _, _ in try change(-1) }))
        /// ]/[: the start of the next (previous) change — a run of changed lines with nothing unchanged
        /// between them, finer than git's hunk (which can hold two edits) — crossing into the next file.
        func change(_ dir: Int) throws {
            let s = pg.stops
            let starts = pg.changeStarts
            let i = idx()
            let target: Int?
            if dir > 0 {
                target = starts.first { $0 > i }
            } else {
                let cur = starts.last { $0 <= i }
                let inside = cur.map { c in (c...i).allSatisfy { k in s[k].row.map(changed) ?? (s[k].kind == .thread || s[k].kind == .pending) } } ?? false
                target = inside ? starts.last { $0 < cur! } : cur
            }
            guard let target else {
                if dir > 0 { throw Refusal(pg.neighbour(1) != nil ? "the last change · J the next branch" : "the last change in this branch") }
                throw Refusal(pg.neighbour(-1) != nil ? "the first change · K the branch before" : "the first change in this branch")
            }
            if app.keys.mode != .select { pg.mark = nil }
            goTo(target)
        }
        r.register(Command(id: "review.file.next", title: "Go to the next file", scope: .review, verb: .nextFile, modes: motion,
                           label: "file", pair: "review.file.prev", available: onDiff,
                           local: { _, _ in try file(1) }))
        r.register(Command(id: "review.file.prev", title: "Go to the previous file", scope: .review, verb: .previousFile, modes: motion,
                           label: "file", available: onDiff,
                           local: { _, _ in try file(-1) }))
        /// n/N: open conversations first, then any.
        func thread(_ dir: Int) throws {
            func openOne(_ s: Stop) -> Bool {
                guard s.kind == .thread, let t = s.id.flatMap({ app.store.view(CanopyCore.Thread.self, $0) }) else { return false }
                return !t.resolved && !t.outdated
            }
            let search = PageSearch.of(app)
            if search.active && !search.typing {
                if !search.step(app, dir) { throw Refusal("no matches") }
                return
            }
            if (try? seek(dir, openOne)) != nil { return }
            try seek(dir) { $0.kind == .thread }
        }
        r.register(Command(id: "review.thread.next", title: "Go to the next conversation (open ones first)", scope: .review,
                           verb: .nextThread, label: "thread", pair: "review.thread.prev", available: onDiff,
                           local: { _, _ in try thread(1) }))
        r.register(Command(id: "review.thread.prev", title: "Go to the previous conversation (open ones first)", scope: .review,
                           verb: .previousThread, label: "thread", available: onDiff,
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
                               if let path = arg as? String, let k = pg.landing(file: path) { pg.setCursor(k) }
                           }))
        r.register(Command(id: "review.in", title: "Into the diff at the file", scope: .review, verb: .main, label: "in",
                           available: { _ in app.pane?.id == reviewTreePane && onFiles(nil) },
                           route: { _ in
                               guard let row = app.selected, row.hasPrefix("f|") else { return nil }
                               return RouteTo("review.file.go", arg: String(row.dropFirst(2)))
                           }))
        r.register(Command(id: "review.extend", title: "Extend the selection a line (comment on a range)", scope: .line, verb: .extend, label: "range",
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
        r.register(Command(id: "review.branch.next", title: "Review the next branch in merge order", scope: .review, verb: .nextSibling,
                           label: "branch", pair: "review.branch.prev", available: isBranch, local: { _, _ in try hop(pg.neighbour(1)) }))
        r.register(Command(id: "review.branch.prev", title: "Review the previous branch in merge order", scope: .review, verb: .previousSibling,
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
        r.register(Command(id: "review.parent", title: "Review its parent branch", scope: .review, verb: .parent, label: "parent",
                           available: isBranch, local: { _, _ in try hop(pg.branch?.parentId.flatMap { app.store.view(Branch.self, $0) }) }))
        r.register(Command(id: "review.child", title: "Review a child branch (which one, at a fan-out)", scope: .review, verb: .child,
                           label: "child", available: isBranch,
                           local: { _, _ in
                               let kids = children(pg.id)
                               if kids.count > 1 { return pickChild(kids) { b in MainActor.assumeIsolated { _ = try? hop(b) } } }
                               try hop(kids.first)
                           }))
        r.register(Command(id: "review.root", title: "Review the stack's root", scope: .review, verb: .root, label: "root",
                           available: isBranch,
                           local: { _, _ in
                               var b = pg.branch
                               var n = 0
                               while let p = b?.parentId.flatMap({ app.store.view(Branch.self, $0) }), n < 64 { b = p; n += 1 }
                               if b?.id == pg.id { throw Refusal("this is the root") }
                               try hop(b)
                           }))
        r.register(Command(id: "review.tip", title: "Review the stack's tip (which one, at a fan-out)", scope: .review, verb: .tip, label: "tip",
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
        r.register(Command(id: "review.tab", title: "Cycle the tabs", scope: .review, verb: .face, label: "tab",
                           local: { _, _ in pg.tab = tabs[((tabs.firstIndex(of: pg.tab) ?? 2) + 1) % tabs.count] }))
        for (i, t) in tabs.enumerated() {
            r.register(Command(id: "review.tab.\(t)", title: t == "files" ? "Show the code (the files tab)" : "Show the \(t) tab", scope: .review, verb: .nth(i + 1), label: t,
                               local: { _, _ in pg.tab = t }))
        }
        r.register(Command(id: "review.outdated", title: "Show or hide outdated conversations", scope: .review, leader: LocalKey(",o"), label: "outdated",
                           local: { _, _ in pg.showOutdated.toggle() }))

        func baseOK(_ b: ReviewBase) -> Bool { pg.integration == nil && (b != .outgoing || (pg.branch != nil && pg.branch?.pushed != .local)) }
        for (b, k, title) in [(ReviewBase.parent, "p", "Diff against its parent — this branch's own change, what the PR shows"),
                              (.main, "m", "Diff against main — the whole stack up to here, as it would land"),
                              (.outgoing, "o", "Diff against origin — what the next push sends")] {
            r.register(Command(id: "review.base.\(b.word)", title: title, scope: .review, leader: LocalKey(",b \(k)"), label: b.word,
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
        r.register(Command(id: "review.filter", title: "Find a file (filter the tree)", scope: .review, verb: .find, label: "find",
                           local: { _, _ in
                               pg.tab = "files"
                               app.focus(pane: reviewTreePane)
                               app.beginInsert(ReviewPage.filterField)
                           }))
        r.register(Command(id: "review.files", title: "The files this branch changes: j k to one, ↵ goes there", scope: .review, verb: .changedFiles, label: "files",
                           local: { _, _ in
                               pg.tab = "files"
                               app.focus(pane: reviewTreePane)
                           }))
        r.register(Command(id: "review.filter.accept", title: "Go to the first file the filter finds", scope: .filter, verb: .send, modes: [.insert], quiet: true,
                           available: { _ in app.insertField == ReviewPage.filterField },
                           local: { _, _ in
                               app.keys.setMode(.normal)
                               guard let first = ReviewPage.treeRows(pg).first else { throw Refusal("no file matches") }
                               app.runner.dispatch("review.file.go", via: .key, arg: String(first.dropFirst(2)))
                           }))

        // ── the map (space m): a layer; its keys are the verbs' ──

        r.register(Command(id: "review.map", title: "Show the forest map", scope: .review, verb: .map, label: "map",
                           local: { _, _ in
                               if app.keys.layer == .map { return app.keys.closeLayer() }
                               pg.mapIndex = max(0, ReviewMap.rows(app).firstIndex { $0.id == pg.id } ?? 0)
                               app.keys.openLayer(.map)
                           }))
        r.register(Command(id: "review.map.down", title: "Next branch on the map", scope: .review, verb: .next, modes: [.map], quiet: true,
                           local: { _, _ in
                               let last = max(0, ReviewMap.rows(app).count - 1)
                               if pg.mapIndex >= last { throw Refusal("the last branch on the map") }
                               pg.mapIndex += 1
                           }))
        r.register(Command(id: "review.map.up", title: "Previous branch on the map", scope: .review, verb: .previous, modes: [.map], quiet: true,
                           local: { _, _ in
                               if pg.mapIndex <= 0 { throw Refusal("the first branch on the map") }
                               pg.mapIndex -= 1
                           }))
        r.register(Command(id: "review.map.open", title: "Open the branch under the map's cursor", scope: .review, verbs: [.main], modes: [.map], quiet: true,
                           route: { _ in
                               let rows = ReviewMap.rows(app)
                               return rows.indices.contains(pg.mapIndex) ? RouteTo("review.map.go", arg: rows[pg.mapIndex].id) : nil
                           }))
        r.register(Command(id: "review.map.page", title: "Go to the forest's page", scope: .review, verb: .out, modes: [.map], quiet: true,
                           local: { _, _ in app.keys.closeLayer(); app.runner.dispatch("review.leave", via: .key) }))
        r.register(Command(id: "review.map.go", title: "Open a branch from the map", scope: .review, needsArg: true, quiet: true,
                           local: { _, arg in
                               if app.keys.layer == .map { app.keys.closeLayer() }
                               guard let id = arg as? String, let cut = id.firstIndex(of: ":") else { return }
                               app.go(.review(repo: String(id[..<cut]), branch: String(id[id.index(after: cut)...])))
                           }))

        // ── hidden lines ──

        r.register(Command(id: "review.expand", title: "Show 20 more hidden lines", scope: .gap, verb: .main, label: "more",
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

        r.register(Command(id: "review.leave", title: "Go back to its forest", scope: .review, verb: .out, label: "back",
                           local: { _, _ in
                               let pid = pg.branch?.project ?? pg.integration
                               guard let pid, let p = app.store.view(Project.self, pid) else { return app.go(.forests) }
                               let id = pg.id
                               app.go(.forest(repo: p.repo, project: p.name))
                               if pg.integration == nil { app.setCursor(RowKey.branch(id)) }
                           }))
        // ── h / l: one character along the code under the cursor. Past a half's edge, into the other
        // half where the old one differs (a removed line). In the panes without code (the files, the
        // commits) they still move to the pane beside; ⌃h / ⌃l move panes from anywhere. ──

        func sideCharStep(_ d: Int) throws {
            guard let line = RowKey.id(app.selected, "s").flatMap(Int.init) else { throw Refusal("no line here") }
            let lines = (pg.sideText ?? "").components(separatedBy: "\n")
            let t = line >= 1 && line <= lines.count ? lines[line - 1] : ""
            guard let r = stepped(t, from: pg.sideHereWord, d) else { throw Refusal(d < 0 ? "start of the line" : "end of the line") }
            pg.sideWord = (line, r)
        }
        func horizontal(_ d: Int) throws {
            switch app.pane?.id {
            case reviewDiffPane: try charStep(d)
            case reviewCodePane where pg.side != nil: try sideCharStep(d)
            default: if !app.focus(d < 0 ? .left : .right) { throw Refusal(d < 0 ? "nothing to the left" : "nothing to the right") }
            }
        }
        r.register(Command(id: "review.left", title: "A character left (in the diff, onto the old half at the line's start)", scope: .review, verb: .left, quiet: true,
                           local: { _, _ in try horizontal(-1) }))
        r.register(Command(id: "review.right", title: "A character right (from the old half's end, onto the new half)", scope: .review, verb: .right, quiet: true,
                           local: { _, _ in try horizontal(1) }))
        // ── w / b: name to name, across lines — the name g d and space k then ask about ──

        /// The names on a line stop's current half (the old half only as far as it's drawn).
        func names(_ s: Stop) -> (side: Side, names: [Range<Int>])? {
            guard s.kind == .line, let row = s.row else { return nil }
            let side = sideLine(row, prefer: pg.column).side
            guard let text = (side == .left ? row.left : row.right)?.text else { return nil }
            let all = CodeLookup.names(text)
            return (side, side == .left ? all.filter { $0.upperBound < pg.splitWidth(s.path) } : all)
        }
        /// The code beside the diff: name to name across its lines.
        func sideStep(_ d: Int) throws {
            let lines = (pg.sideText ?? "").components(separatedBy: "\n")
            guard var n = RowKey.id(app.selected, "s").flatMap(Int.init) else { throw Refusal("no line here") }
            var from = pg.sideHereWord
            while n >= 1 && n <= lines.count {
                let ns = CodeLookup.names(lines[n - 1])
                let pick = d > 0 ? ns.first { from == nil || $0.lowerBound > from!.lowerBound } : ns.last { from == nil || $0.lowerBound < from!.lowerBound }
                if let pick {
                    if app.selected != "s:\(n)" { app.setCursor("s:\(n)") }
                    pg.sideWord = (n, pick)
                    return
                }
                from = nil
                n += d
            }
            throw Refusal(d > 0 ? "no more names below" : "no more names above")
        }
        func step(_ d: Int) throws {
            if app.pane?.id == reviewCodePane, pg.side != nil { return try sideStep(d) }
            // names live in code: from a list pane, w / b go into the diff and step there
            if app.pane?.id != reviewDiffPane { app.focus(pane: reviewDiffPane) }
            guard app.pane?.id == reviewDiffPane, var i = pg.here.flatMap({ pg.stopIndex[$0.key] }) else { throw Refusal("no diff to step through") }
            var from = pg.hereWord
            while i >= 0 && i < pg.stops.count {
                let s = pg.stops[i]
                if let (side, ns) = names(s) {
                    let pick = d > 0 ? ns.first { from == nil || $0.lowerBound > from!.lowerBound } : ns.last { from == nil || $0.lowerBound < from!.lowerBound }
                    if let pick {
                        if s.key != pg.here?.key { pg.setCursor(s.key) }
                        pg.word = (s.key, side, pick)
                        return
                    }
                }
                from = nil
                i += d
            }
            throw Refusal(d > 0 ? "no more names below" : "no more names above")
        }
        /// `*`: the name under the cursor (w's, else the line's first), as a kept search from there.
        func searchWord() throws {
            let search = PageSearch.of(app)
            if app.pane?.id == reviewCodePane, pg.side != nil {
                guard let n = RowKey.id(app.selected, "s").flatMap(Int.init) else { throw Refusal("no name here") }
                let lines = (pg.sideText ?? "").components(separatedBy: "\n")
                let text = n >= 1 && n <= lines.count ? lines[n - 1] : ""
                guard let w = pg.sideHereWord ?? CodeLookup.names(text).first else { throw Refusal("no name on this line") }
                let q = (text as NSString).substring(with: NSRange(location: w.lowerBound, length: w.count))
                if !search.seek(app, q, at: PageSearch.Hit(row: "s:\(n)", field: 0, at: w)) { throw Refusal("no matches") }
                return
            }
            guard app.pane?.id == reviewDiffPane, let h = pg.here, let (side, ns) = names(h), let w = pg.hereWord ?? ns.first,
                  let text = (side == .left ? h.row?.left : h.row?.right)?.text else { throw Refusal("no name here") }
            let q = (text as NSString).substring(with: NSRange(location: w.lowerBound, length: w.count))
            if !search.seek(app, q, at: PageSearch.Hit(row: h.key, field: side == .right ? 0 : 1, at: w)) { throw Refusal("no matches") }
        }
        r.register(Command(id: "review.search.word", title: "Search for the name under the cursor", scope: .review, verb: .searchWord, label: "search name",
                           local: { _, _ in try searchWord() }))
        r.register(Command(id: "review.word.next", title: "The next name", scope: .review, verb: .nextWord, quiet: true,
                           local: { _, _ in try step(1) }))
        r.register(Command(id: "review.word.previous", title: "The previous name", scope: .review, verb: .previousWord, quiet: true,
                           local: { _, _ in try step(-1) }))
        // ── along the line, as Helix: g h / g l / g s to its start, end and first non-blank; f / t / F / T
        // to a character typed next ──

        /// Put the character cursor at the offset `pick` chooses on the line under the cursor, diff or side.
        func onLine(_ edge: String, _ pick: (String, Range<Int>?) -> Int?) throws {
            if app.pane?.id == reviewCodePane, pg.side != nil {
                guard let line = RowKey.id(app.selected, "s").flatMap(Int.init) else { throw Refusal("no line here") }
                let lines = (pg.sideText ?? "").components(separatedBy: "\n")
                let t = line >= 1 && line <= lines.count ? lines[line - 1] : ""
                guard !t.isEmpty, let at = pick(t, pg.sideHereWord) else { throw Refusal(edge) }
                pg.sideWord = (line, char(t, at))
                return
            }
            guard app.pane?.id == reviewDiffPane, let h = pg.here, h.kind == .line, let row = h.row else { throw Refusal("no code on this row") }
            let side = sideLine(row, prefer: pg.column).side
            let t = halfText(h, side) ?? ""
            guard !t.isEmpty, let at = pick(t, pg.hereWord) else { throw Refusal(edge) }
            let r = char(t, at)
            if r == pg.hereWord { throw Refusal(edge) }
            pg.word = (h.key, side, r)
            (goal, placed, carried) = (r.lowerBound, r.lowerBound, h.key)
            pg.cursorMoved &+= 1
        }
        let len: (String) -> Int = { ($0 as NSString).length }
        r.register(Command(id: "review.line.start", title: "The start of the line", scope: .review, verb: .lineStart, modes: motion, quiet: true,
                           local: { _, _ in try onLine("already at the line's start") { _, _ in 0 } }))
        r.register(Command(id: "review.line.end", title: "The end of the line", scope: .review, verb: .lineEnd, modes: motion, quiet: true,
                           local: { _, _ in try onLine("already at the line's end") { t, _ in len(t) - 1 } }))
        r.register(Command(id: "review.line.first", title: "The line's first non-blank", scope: .review, verb: .firstNonBlank, modes: motion, quiet: true,
                           local: { _, _ in try onLine("already at the first non-blank") { t, _ in min(firstNonBlank(t), len(t) - 1) } }))

        /// Where f / t / F / T land for `c` on `t`, from the character cursor `w`: nil when it isn't there.
        func seekChar(_ t: String, _ w: Range<Int>?, _ c: String, back: Bool, till: Bool) -> Int? {
            let ns = t as NSString
            let n = ns.length
            let here = w?.lowerBound ?? (back ? n : -1)
            if back {
                let end = here - (till ? 1 : 0)
                guard end > 0 else { return nil }
                let found = ns.range(of: c, options: .backwards, range: NSRange(location: 0, length: end))
                guard found.location != NSNotFound else { return nil }
                return till ? found.location + found.length : found.location
            }
            let from = max(0, (w?.upperBound ?? 0) + (till && w != nil ? 1 : 0))
            guard from < n else { return nil }
            let found = ns.range(of: c, range: NSRange(location: from, length: n - from))
            guard found.location != NSNotFound else { return nil }
            return till ? (found.location > from ? found.location - 1 : nil) : found.location
        }
        var seeking: (back: Bool, till: Bool)?
        var lastSeek: (back: Bool, till: Bool, c: String)?
        app.keys.layerKeys[findCharLayer] = { [weak app] k in
            guard let app else { return false }
            app.keys.closeLayer()
            guard let how = seeking, k.count == 1 || k == "space" else { return true }
            let c = k == "space" ? " " : k
            lastSeek = (how.back, how.till, c)
            do {
                try onLine("no \(c) \(how.back ? "before" : "after") the cursor on this line") { t, w in seekChar(t, w, c, back: how.back, till: how.till) }
            } catch let e as Refusal { app.runner.say(e.message) } catch {}
            return true
        }
        for (id, verb, back, till, what) in [("review.find.char", Verb.findChar, false, false, "on to"), ("review.till.char", .tillChar, false, true, "up to"),
                                             ("review.find.back", .findCharBack, true, false, "back to"), ("review.till.back", .tillCharBack, true, true, "back to just after")] {
            r.register(Command(id: id, title: "\(what.prefix(1).uppercased() + what.dropFirst()) a character you type next, along the line", scope: .review,
                               verb: verb, modes: motion, quiet: true,
                               local: { _, _ in
                                   let inCode = (app.pane?.id == reviewCodePane && pg.side != nil) || (app.pane?.id == reviewDiffPane && pg.here?.kind == .line)
                                   guard inCode else { throw Refusal("f / t find a character along a line of code — g w labels the screen") }
                                   seeking = (back, till)
                                   app.keys.openLayer(findCharLayer)
                               }))
        }
        r.register(Command(id: "review.seek.again", title: "Repeat the last f / t / F / T", scope: .review, verb: .repeatMotion, modes: motion, quiet: true,
                           local: { _, _ in
                               guard let l = lastSeek else { throw Refusal("nothing to repeat yet — f / t / F / T first") }
                               try onLine("no \(l.c) \(l.back ? "before" : "after") the cursor on this line") { t, w in seekChar(t, w, l.c, back: l.back, till: l.till) }
                           }))

        // ── ]G / [G: the branch's last and first change ──
        r.register(Command(id: "review.change.last", title: "The branch's last change", scope: .review, verb: .lastChange, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try ends(first: false) }))
        r.register(Command(id: "review.change.first", title: "The branch's first change", scope: .review, verb: .firstChange, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try ends(first: true) }))

        // ── z: where the cursor's line sits on screen ──
        for (id, verb, at, what) in [("review.view.center", Verb.viewCenter, 0.5, "middle"), ("review.view.top", .viewTop, 0.0, "top"),
                                     ("review.view.bottom", .viewBottom, 1.0, "bottom")] {
            r.register(Command(id: id, title: "Scroll the cursor's line to the \(what)", scope: .review, verb: verb, modes: motion, quiet: true,
                               local: { _, _ in
                                   guard app.pane?.id == reviewDiffPane, let k = pg.diffCursor else { throw Refusal("z scrolls the diff — this pane follows its cursor") }
                                   if !pg.diffCanvas.canvas.place(k, at: at) { throw Refusal("the diff isn't drawn yet") }
                               }))
        }

        // ── ]f / ]t: the next function or type in this file's diff, by the file's symbols ──

        /// The diff's new-side line under the cursor (a removed line counts as the line after it).
        func newLine(_ s: Stop?) -> Int {
            guard let row = s?.row else { return 0 }
            return row.right?.new ?? row.left?.new ?? 0
        }
        /// The stop a symbol lands on: its first line if the diff shows it, else its first line the diff does.
        func landing(_ sym: LSPSymbols.Symbol, in path: String) -> Int? {
            var best: (line: Int, i: Int)?
            for (i, s) in pg.stops.enumerated() where s.path == path && s.kind == .line {
                guard let n = s.row?.right?.new, n >= sym.line, n <= max(sym.line, sym.endLine) else { continue }
                if best == nil || n < best!.line { best = (n, i) }
            }
            return best?.i
        }
        func symbolStep(_ dir: Int, kinds: Set<String>, noun: String) throws {
            guard app.pane?.id == reviewDiffPane, let here = pg.here, let path = here.path as String?, !path.isEmpty else {
                throw Refusal("] f / ] t walk the diff's code")
            }
            let (_, w) = position()
            guard let w else { throw Refusal("no code here") }
            let from = idx()
            let look = CodeLookup.of(app)
            Task { @MainActor in
                guard let syms = await look.symbolList(path: path, w) else { return }
                guard pg.here?.key == here.key else { return }   // the cursor moved on while tsgo answered
                let marks = syms.filter { kinds.contains($0.kind) }.compactMap { s in landing(s, in: path).map { (s, $0) } }
                let pick = dir > 0 ? marks.filter { $0.1 > from }.min { $0.1 < $1.1 } : marks.filter { $0.1 < from }.max { $0.1 < $1.1 }
                guard let (sym, i) = pick else {
                    app.runner.say(marks.isEmpty ? "no \(noun) in this file's diff" : dir > 0 ? "the last \(noun) in this file's diff" : "the first \(noun) in this file's diff")
                    return
                }
                if app.keys.mode != .select { pg.mark = nil }
                goTo(i)
                app.runner.say("\(sym.kind) \(sym.name)")
            }
        }
        let functions: Set<String> = ["function", "method", "constructor"]
        let types: Set<String> = ["class", "interface", "enum", "struct"]
        r.register(Command(id: "review.function.next", title: "The next function", scope: .review, verb: .nextFunction, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try symbolStep(1, kinds: functions, noun: "function") }))
        r.register(Command(id: "review.function.prev", title: "The previous function", scope: .review, verb: .previousFunction, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try symbolStep(-1, kinds: functions, noun: "function") }))
        r.register(Command(id: "review.type.next", title: "The next class, interface or enum", scope: .review, verb: .nextType, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try symbolStep(1, kinds: types, noun: "type") }))
        r.register(Command(id: "review.type.prev", title: "The previous class, interface or enum", scope: .review, verb: .previousType, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try symbolStep(-1, kinds: types, noun: "type") }))

        // ── ]d / [d: push-ready's findings, as Helix walks diagnostics ──

        /// Each finding's stop: its line (the nearest the diff shows), else its file's first change.
        func findingStops(_ fs: [ReviewFlag]) -> [(i: Int, n: Int, flag: ReviewFlag)] {
            var out: [(Int, Int, ReviewFlag)] = []
            for (n, f) in fs.enumerated() {
                guard let path = f.path, pg.stopFiles.contains(path) else { continue }
                if let line = f.line {
                    let near = pg.stops.enumerated().filter { $0.element.path == path && $0.element.kind == .line && $0.element.row?.right?.new != nil }
                        .min { abs($0.element.row!.right!.new! - line) < abs($1.element.row!.right!.new! - line) }
                    if let near { out.append((near.offset, n, f)); continue }
                }
                if let k = pg.landing(file: path), let i = pg.stopIndex[k] { out.append((i, n, f)) }
            }
            return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        }
        var shownFinding: (key: String, n: Int)?
        func findingStep(_ dir: Int) throws {
            guard let t = pg.target else { throw Refusal("no branch here") }
            let at = idx()
            let flags = ReviewFlags.of(app)
            Task { @MainActor in
                guard let fs = await flags.load(app, t) else {
                    app.runner.say("no findings on this tree — push-ready's review hasn't run since the last edit")
                    return
                }
                if fs.isEmpty { app.runner.say("push-ready's review found nothing here"); return }
                let all = findingStops(fs)
                let outside = fs.count - all.count
                let shown = shownFinding.flatMap { s in pg.here?.key == s.key ? s.n : nil }
                let pick = dir > 0
                    ? all.first { f in f.i > at || (f.i == at && f.n > (shown ?? -1)) }   // the one you stand on first
                    : all.last { f in f.i < at || (f.i == at && shown.map { f.n < $0 } ?? false) }
                guard let p = pick else {
                    let rest = outside > 0 ? " · \(outside) more on code this diff doesn't show" : ""
                    app.runner.say(all.isEmpty ? "\(fs.count) findings, none on this diff's code" : (dir > 0 ? "the last finding" : "the first finding") + rest)
                    return
                }
                if app.keys.mode != .select { pg.mark = nil }
                goTo(p.i)
                shownFinding = (pg.here?.key ?? "", p.n)
                let k = (all.firstIndex { $0.n == p.n } ?? 0) + 1
                app.runner.say("finding \(k) of \(all.count): \(p.flag.text)")
            }
        }
        r.register(Command(id: "review.finding.next", title: "The next review finding", scope: .review, verb: .nextFinding, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try findingStep(1) }))
        r.register(Command(id: "review.finding.prev", title: "The previous review finding", scope: .review, verb: .previousFinding, modes: motion, quiet: true,
                           available: onDiff, local: { _, _ in try findingStep(-1) }))

        r.register(Command(id: "review.conversation", title: "The conversation, in place of the diff (esc brings the diff back)", scope: .review,
                           verb: .conversation, label: "conversation", available: { _ in pg.integration == nil },
                           local: { _, _ in
                               if pg.tab == "conversation" { pg.tab = "files"; return app.focus(pane: reviewDiffPane) }
                               PageSearch.of(app).clear()   // a search belongs to what it searched
                               pg.tab = "conversation"
                               if let first = app.panes.first { app.focus(pane: first.id) }
                           }))
        r.register(Command(id: "review.back", title: "Back out", scope: .review, verb: .cancel, label: "back", quiet: true,
                           local: { _, _ in
                               if ShipSeam.backOut(app) { return }
                               let look = CodeLookup.of(app)
                               if look.pop != nil { return look.dismiss() }
                               if app.nav.picker != nil { return app.nav.close() }
                               if PageSearch.of(app).active { return PageSearch.of(app).clear() }
                               if pg.tab != "files" { pg.tab = "files"; return app.focus(pane: reviewDiffPane) }
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
                let pos = pg.sideHereWord.flatMap { CodeLookup.position(path: s.path, line: n, text: text, at: $0.lowerBound) }
                    ?? CodeLookup.position(path: s.path, line: n, text: text)
                return (pos, .commit(repo: s.repo, sha: s.sha))
            }
            let w = CodeLookup.Where.branch(repo: t.repo, name: t.name, base: pg.baseSha)
            if let p = pg.pointer, p.seq == pg.cursorMoved, p.key == pg.here?.key {
                if pg.scoped, let sha = pg.commitScope { return (p.pos, .commit(repo: t.repo, sha: sha)) }
                return (p.pos, w)
            }
            guard let h = pg.here, h.kind == .line, let row = h.row else { return (nil, w) }
            let old = sideLine(row, prefer: pg.column).side == .left
            let l = (old ? row.left : row.right)!
            let pos = pg.hereWord.flatMap { CodeLookup.position(path: h.path, line: (old ? l.old : l.new) ?? 1, text: l.text, at: $0.lowerBound, side: old ? "old" : "new") }
                ?? CodeLookup.position(path: h.path, line: (old ? l.old : l.new) ?? 1, text: l.text, side: old ? "old" : "new")
            if pg.scoped, let sha = pg.commitScope { return (pos, .commit(repo: t.repo, sha: sha)) }
            return (pos, w)
        }
        let codeOK: (String?) -> Bool = { _ in onFiles(nil) || app.pane?.id == reviewCodePane || pg.scoped }
        r.register(Command(id: "review.rename", title: "Rename the name under the cursor (a commit you see first)", scope: .review, verb: .rename, label: "rename",
                           available: { _ in onFiles(nil) && !pg.scoped && pg.integration == nil && app.pane?.id == reviewDiffPane },
                           local: { _, _ in
                               guard let t = pg.target else { return }
                               let (p, _) = position()
                               CodeLookup.of(app).rename(p, branch: t.name, repo: t.repo)
                           }))
        r.register(Command(id: "review.types", title: "Show the type (hover)", scope: .review, verb: .type, label: "type", available: codeOK,
                           local: { _, _ in let (p, w) = position(); CodeLookup.of(app).hover(p, w) }))
        for (id, kind, verb, title, label) in [("review.definition", LSPGoto.definition, Verb.definition, "Go to the definition — in the diff when it's there, else beside it", "def"),
                                              ("review.type-definition", .typeDefinition, .typeDefinition, "Go to the definition of its type", "type def"),
                                              ("review.implementation", .implementation, .implementations, "Go to its implementations", "impl"),
                                              ("review.references", .references, .references, "List its references", "refs")] {
            r.register(Command(id: id, title: title, scope: .review, verb: verb, label: label, available: codeOK,
                               local: { _, _ in let (p, w) = position(); CodeLookup.of(app).goto(kind, p, w) }))
        }
        r.register(Command(id: "review.symbols", title: "List the file's symbols", scope: .review, verb: .symbols, label: "symbols", available: codeOK,
                           local: { _, _ in
                               let (p, w) = position()
                               let path = p?.path ?? (app.pane?.id == reviewCodePane ? pg.side?.path : pg.here?.path)
                               CodeLookup.of(app).symbols(path: path, side: p?.side ?? "new", w)
                           }))
        r.register(Command(id: "review.side.close", title: "Close the code beside the diff", scope: .review, quiet: true,
                           available: { _ in pg.side != nil }, local: { _, _ in pg.closeSide() }))
        r.register(Command(id: "review.side.extend", title: "Select this line, then the next (the code beside the diff)", scope: .review, verb: .extend,
                           modes: [.normal, .select], label: "range", group: .move, available: { _ in pg.side != nil && app.pane?.id == reviewCodePane },
                           local: { _, _ in
                               if app.keys.mode != .select { app.anchorHere(); return app.keys.setMode(.select) }
                               guard let n = RowKey.id(app.selected, "s").flatMap(Int.init), n < pg.sideRows.count else { return }
                               app.setCursor("s:\(n + 1)")
                           }))

        // ── space o m / space o b: these lines on GitHub (Helix's gh-open keys) ──

        /// The lines under the cursor or selection: the code beside the diff's at its commit, else the diff's at the tip.
        func githubLines() -> (path: String, lines: ClosedRange<Int>, sha: String?)? {
            if let s = pg.side, app.pane?.id == reviewCodePane {
                let ns = app.selection.compactMap { RowKey.id($0, "s").flatMap(Int.init) }
                guard let lo = ns.min(), let hi = ns.max() else { return nil }
                return (s.path, lo...hi, s.sha)
            }
            guard app.pane?.id == reviewDiffPane, let h = pg.here, h.kind == .line || h.kind == .file else { return nil }
            if app.keys.mode == .select {
                let ns = app.selection.compactMap { pg.stopIndex[$0].map { pg.stops[$0] } }.filter { $0.path == h.path }.compactMap { $0.row?.right?.new }
                if let lo = ns.min(), let hi = ns.max() { return (h.path, lo...hi, nil) }
            }
            if let r = pg.range, r.path == h.path, r.side == .right { return (h.path, (r.startLine ?? r.line)...r.line, nil) }
            return pg.tipLineNear(h).map { (h.path, $0...$0, nil) }
        }
        func openOnGitHub(main: Bool) throws {
            guard let t = pg.target, let at = githubLines() else { throw Refusal("no lines here to open") }
            let ref = main ? "main" : at.sha ?? t.name
            let frag = at.lines.count > 1 ? "#L\(at.lines.lowerBound)-L\(at.lines.upperBound)" : "#L\(at.lines.lowerBound)"
            let ship = ShipState.of(app)
            Task { @MainActor in
                guard let web = await pg.githubPage(app) else { return app.runner.say("couldn't read origin's GitHub address for \(t.repo)") }
                let path = at.path.split(separator: "/").map { String($0).uriComponent }.joined(separator: "/")
                if let u = URL(string: "\(web)/blob/\(ref.uriComponent)/\(path)\(frag)") { ship.openURL(u) }
            }
        }
        r.register(Command(id: "review.github.main", title: "Open these lines on GitHub, on main", scope: .review, verb: .githubMain,
                           modes: [.normal, .select], label: "gh main", available: { _ in githubLines() != nil },
                           local: { _, _ in try openOnGitHub(main: true) }))
        r.register(Command(id: "review.github.branch", title: "Open these lines on GitHub at the branch — the code beside the diff, at its commit", scope: .review,
                           verb: .githubBranch, modes: [.normal, .select], label: "gh branch", available: { _ in githubLines() != nil },
                           local: { _, _ in try openOnGitHub(main: false) }))

        r.register(Command(id: "review.open", title: "Open the file in Helix, over the diff — quitting commits what changed", scope: .review,
                           verb: .editor, label: "helix",
                           available: { _ in pg.integration == nil && pg.helix == nil },
                           local: { _, _ in if !pg.openHelixWhole(app) { throw Refusal("nothing to open here") } }))

        r.register(Command(id: "review.match", title: "The other half of this edit — what replaced the line, or what it replaced",
                           scope: .review, verb: .match, label: "match", available: onDiff,
                           local: { _, _ in
                               guard let h = pg.here, h.kind == .line, let row = h.row, changed(row) else { throw Refusal("m m matches a changed line's two halves — this row has none") }
                               let side = sideLine(row, prefer: pg.column).side
                               let other: Side = side == .left ? .right : .left
                               guard let o = halfText(h, other), !o.isEmpty else {
                                   throw Refusal(row.left?.kind == .del ? "only removed — nothing replaced it" : "only added — it replaced nothing")
                               }
                               let r = char(o, min(pg.hereWord?.lowerBound ?? firstNonBlank(o), (o as NSString).length - 1))
                               pg.column = other
                               pg.word = (h.key, other, r)
                               (goal, placed, carried) = (r.lowerBound, r.lowerBound, h.key)
                               pg.cursorMoved &+= 1
                           }))

        // ── viewed: , m marks and moves on, , M takes it back ──

        r.register(Command(id: "review.viewed", title: "Mark viewed and go on to the next unviewed — the hunk, the file on its header, the range in select",
                           scope: .review, budget: .configWrite, verb: .mark, leader: LocalKey(",m"), modes: motion, label: "viewed", pair: "review.unviewed",
                           available: { _ in onDiff(nil) && pg.here != nil && !pg.scoped },
                           write: { _, _ in
                               let w = viewed(app, pg, on: true)
                               if app.keys.mode == .select { app.keys.setMode(.normal) }
                               return w
                           }))
        r.register(Command(id: "review.unviewed", title: "Mark unviewed — the hunk, the file on its header, the range in select",
                           scope: .review, budget: .configWrite, verb: .unmark, leader: LocalKey(",M"), modes: motion, label: "unviewed",
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
        pg.setCursor(pg.landing(file: after?.file.path ?? path) ?? "f|\(path)")
    }
}
