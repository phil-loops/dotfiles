import CanopyCore
import SwiftUI

/// The review page (Review.tsx): GitHub's pull-request review, local. The header (title, the ship
/// strip, the tabs), then the tab — files changed (a file tree with viewed boxes, the diff with its
/// conversations folded in at their lines, a file opened beside it), the conversation (Ship), or the
/// commits (Ship's history, the selected commit's diff drawn here). Everything it does is a command.
struct ReviewPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let route: Route

    static let filterField = "review.filter"

    /// The file tree's rows: every file of the diff the filter keeps ("f|<path>").
    @MainActor static func treeRows(_ pg: ReviewPageState) -> [String] {
        let q = pg.filter.lowercased()
        return pg.views.map(\.file.path).filter { q.isEmpty || $0.lowercased().contains(q) }.map { "f|\($0)" }
    }

    var body: some View {
        let pg = ReviewPageState.of(app)
        VStack(alignment: .leading, spacing: 0) {
            if pg.target == nil {
                Text("no branch in the address").foregroundStyle(theme.inkFaint).padding(16)
            } else {
                ReviewHeader()
                switch pg.tab {
                case "conversation":
                    ConversationPanel(branchID: pg.id).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case "commits":
                    CommitsPanel(branchID: pg.id, diff: pg.scoped ? AnyView(DiffPane(empty: "reading the commit…")) : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                default:
                    HStack(alignment: .top, spacing: 0) {
                        if pg.showsOutline { Outline().frame(width: pg.outlineWidth) }
                        VStack(alignment: .leading, spacing: 8) {
                            if let sha = ShipState.of(app).commitScope {
                                CommitHead(branchID: pg.id, sha: sha).padding(.horizontal, 16).padding(.top, 4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !pg.files.isEmpty { FileBar().padding(.horizontal, 16) }
                            DiffPane(empty: pg.base == .outgoing ? "nothing to push" : "no changes").frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                        .padding(.leading, pg.showsOutline ? 0 : 12)
                        if pg.side != nil { SidePane().frame(width: 520) }
                    }
                    .onChange(of: app.cursors["review/\(ShipSeam.historyPane)"]) { _, k in
                        // the outline's cursor is the diff's scope: a commit, or "= on main" for the whole branch
                        guard let k, k.hasPrefix("h|"), app.pane?.id == ShipSeam.historyPane else { return }
                        let sha = String(k.dropFirst(2))
                        if ShipState.of(app).commitScope != (sha.isEmpty ? nil : sha) { ShipState.of(app).showCommit(sha.isEmpty ? nil : sha) }
                    }
                }
            }
        }
        .overlay { if app.keys.layer == .map { MapOverlay() } }
        .onAppear { pg.sync() }
    }
}

/// What the change is: its title and strips, then who and how big, then the PR's why.
private struct ReviewHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        let c = pg.conv
        let b = pg.branch
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if let c {
                        Text(c.title)
                    } else if let p = pg.integration {
                        Text("✦ \(app.store.view(Project.self, p)?.name ?? p) — every branch merged onto main")
                    } else {
                        Text(b.map { $0.description.isEmpty ? $0.name : $0.description } ?? pg.target?.name ?? "")
                    }
                }
                .font(Theme.display(17)).foregroundStyle(theme.ink).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 16)
                let openThreads = pg.threads.filter { !$0.resolved && !$0.outdated }.count
                Group {
                    if openThreads > 0 { Text("\(openThreads) open").foregroundStyle(theme.ember) }
                    if pg.tab == "conversation" { Text("conversation").foregroundStyle(theme.goldLeaf) }
                    else if pg.branchFiles.count > 1 { Text("\(pg.branchViewed)/\(pg.branchFiles.count) viewed").foregroundStyle(theme.inkFaint) }
                }
                .font(Theme.text(11))
                if pg.integration == nil {
                    ShipStripView(branchID: pg.id)
                    LoopStripView(branchID: pg.id, words: loopWords(pg.id), size: 11)
                        .task(id: b.map { "\($0.id)@\($0.tip)" }) { WordsState.of(app).load(app, pg.id) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let c {
                        Text(c.author).foregroundStyle(theme.inkDim)
                        Text("#\(c.number) → \(c.base)")
                        ForEach(latest(c), id: \.0) { who, st in
                            Text("\(st == "APPROVED" ? "✓" : "✗") \(who)").foregroundStyle(st == "APPROVED" ? theme.patina : theme.ember)
                        }
                        if c.mapping == .behind {
                            Text("\(c.behind) on GitHub not here").foregroundStyle(theme.ember)
                        }
                        let waiting = pg.items.filter { $0.state == .waiting }.count
                        if waiting > 0 { Text("\(waiting) waiting to push").foregroundStyle(theme.goldLeaf) }
                        let drafts = pg.items.filter { $0.state == .draft }.count
                        if drafts > 0 { Text("\(drafts) draft\(drafts == 1 ? "" : "s")").foregroundStyle(theme.goldLeaf) }
                        if let n = c.pending?.count, n > 0 { Text("\(n) pending").foregroundStyle(theme.goldLeaf) }
                    } else if app.store.ready, b?.pushed != .local {
                        Text(noPR(pg))
                    }
                    if let n = b?.commits, n > 0 { Text("\(n) commit\(n == 1 ? "" : "s")") }
                    if !pg.branchFiles.isEmpty { Text("\(pg.branchFiles.count) file\(pg.branchFiles.count == 1 ? "" : "s")") }
            }
            .font(Theme.text(11.5)).foregroundStyle(theme.inkFaint).lineLimit(1)
            if let why = c.flatMap({ Self.why($0.body) }) {
                Text(why).font(Theme.text(12.5)).foregroundStyle(theme.inkDim).lineLimit(2).frame(maxWidth: 760, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
    }

    /// The PR body's opening prose line: what the change is for, ahead of any template below it.
    static func why(_ body: String) -> String? {
        let skip: [String] = ["#", "<!--", "|", ">", "- [", "* [", "```", "---"]
        let line = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !skip.contains(where: $0.hasPrefix) }
        return line.map { Markdown.plain($0, max: 220) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The PR form's title and body hints, for the loop strip's words step (LoopStrip.tsx words);
    /// nil until the branch's /outline is read.
    private func loopWords(_ id: String) -> [LoopWord]? {
        let w = WordsState.of(app)
        guard w.shown[id] != nil else { return nil }
        return w.prHints(id).map { LoopWord(id: $0.id, tone: $0.tone.rawValue) }
    }

    private func latest(_ c: Conv) -> [(String, String)] {
        var by: [(String, String)] = []
        for r in c.reviews where r.state != "COMMENTED" {
            if let i = by.firstIndex(where: { $0.0 == r.author }) { by[i].1 = r.state } else { by.append((r.author, r.state)) }
        }
        return by
    }

    /// What the header says with no conversation yet: a known PR still loading, GitHub not read yet, or none.
    private func noPR(_ pg: ReviewPageState) -> String {
        if let pr = app.store.view(Pr.self, pg.id) { return "#\(pr.number) · loading its conversation…" }
        return app.store.view(Warm.self, pg.target?.repo ?? "")?.prs == true ? "no PR" : "reading GitHub…"
    }
}


/// The file tree: a pane of the diff's files with viewed boxes, its filter on top while finding.
/// The review's table of contents, down the left margin: the branch's commits oldest first with
/// what they land as at the foot (the cursor there scopes the diff), then its files when there are
/// several. Two panes, one above the other: "history" and "files".
private struct Outline: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        VStack(alignment: .leading, spacing: 14) {
            if pg.showsHistory { HistoryList(branchID: pg.id).fixedSize(horizontal: false, vertical: true) }
            if pg.showsTree { FileTree() }
        }
        .font(Theme.text(12))
        .padding(.leading, 6)
        .task(id: app.store.view(Branch.self, pg.id).map(ShipState.historyKey)) {
            ShipState.of(app).loadHistory(app, pg.id)
            WordsState.of(app).load(app, pg.id)
        }
    }
}

private struct FileTree: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var pg = ReviewPageState.of(app)
        let views = Dictionary(pg.views.map { ($0.file.path, $0) }, uniquingKeysWith: { a, _ in a })
        let current = pg.here?.path
        VStack(alignment: .leading, spacing: 0) {
            if app.insertField == ReviewPage.filterField || !pg.filter.isEmpty {
                HStack(spacing: 4) {
                    Text("find").foregroundStyle(theme.goldLeaf)
                    ModalTextField(ReviewPage.filterField, prompt: "filter files…", text: $pg.filter)
                }
                .font(Theme.text(12)).padding(6).background(theme.vellumRaise)
            }
            PaneList(pane: reviewTreePane, rows: ReviewPage.treeRows(pg)) { key, _ in
                let path = String(key.dropFirst(2))
                if let v = views[path] {
                    HStack(spacing: 6) {
                        Text(v.viewed ? "☑" : v.seen > 0 ? "◪" : "☐").foregroundStyle(v.viewed ? theme.patina : theme.inkFaint)
                        PathText(path: path, tint: current == path ? theme.goldLeaf : v.viewed ? theme.inkFaint : theme.ink)
                        Spacer(minLength: 4)
                        if v.open > 0 { Text("\(v.open)").foregroundStyle(theme.ember) }
                        Text("+\(v.file.add)").foregroundStyle(theme.add)
                        Text("−\(v.file.del)").foregroundStyle(theme.del)
                    }
                    .font(Theme.text(11.5))
                    .help(path)
                }
            }
        }
    }
}

/// A path as a reader scans it: the folder quiet, the file name in full; a long folder gives way from its start.
struct PathText: View {
    @Environment(\.theme) private var theme
    let path: String
    let tint: Color

    var body: some View {
        let cut = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        HStack(spacing: 0) {
            Text(path[..<cut]).foregroundStyle(theme.inkFaint).lineLimit(1).truncationMode(.head)
            Text(path[cut...]).foregroundStyle(tint).lineLimit(1).layoutPriority(1)
        }
    }
}

/// The file the cursor is in, over the diff, so the path stays in view however far down it reads.
private struct FileBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        let files = pg.files
        let path = pg.here?.path ?? files.first?.path ?? ""
        let i = files.firstIndex { $0.path == path }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PathText(path: path, tint: theme.ink).font(Theme.text(12.5, weight: .medium))
            if let f = i.map({ files[$0] }) {
                if f.status != .modified { Text(f.status.rawValue).foregroundStyle(theme.inkFaint) }
                if let o = f.oldPath { Text("from \(o)").foregroundStyle(theme.inkFaint).lineLimit(1) }
                Text("+\(f.add)").foregroundStyle(theme.add)
                Text("−\(f.del)").foregroundStyle(theme.del)
            }
            Spacer(minLength: 8)
            if let i, files.count > 1 { Text("file \(i + 1) of \(files.count)").foregroundStyle(theme.inkFaint) }
        }
        .font(Theme.text(11.5))
        .padding(.vertical, 2)
    }
}

/// The diff itself: the canvas over the page state's stops.
private struct DiffPane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let empty: String

    var body: some View {
        let pg = ReviewPageState.of(app)
        let loaded = pg.payload != nil && app.store.ready
        Group {
            if !loaded && !pg.scoped {
                Text(pg.loadErr.map { "couldn't read the diff — \($0)" } ?? "reading the diff…").foregroundStyle(theme.inkFaint).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if pg.files.isEmpty {
                Text(pg.scoped ? "reading the commit…" : empty).foregroundStyle(theme.inkFaint).padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                canvas(pg)
            }
        }
        .paneRing(reviewDiffPane)
        .overlay(alignment: .topLeading) { pop(pg) }
        .overlay(alignment: .topLeading) { helix(pg) }
    }

    /// Helix over the new half, from the column the split puts it at; the old half stays to read against.
    @ViewBuilder private func helix(_ pg: ReviewPageState) -> some View {
        if let h = pg.helix, let dir = h.dir {
            HelixHalf(open: h, dir: dir, colors: CanvasColors(theme)) { pg.landHelix(app) }
                .id("\(dir)|\(h.path)")
                .padding(.leading, CGFloat(pg.splitWidth(h.path) + 7) * DocFont.charWidth + 1)
        }
    }

    private func canvas(_ pg: ReviewPageState) -> some View {
        let colors = CanvasColors(theme)
        let here = pg.here
        let focused = app.isFocused(reviewDiffPane)
        var marks = CanvasMarks(cursor: here?.key, column: pg.column, focused: focused)
        let search = PageSearch.of(app)
        if search.active && search.pane == reviewDiffPane { marks.search = search.query }
        if let w = pg.hereWord, let k = here?.key, let row = here?.row {
            let start = sideLine(row, prefer: pg.column).side == .left ? 6 : pg.splitWidth(here?.path) + 13
            marks.word = (k, (start + w.lowerBound)..<(start + w.upperBound))
        }
        // the range x selected, or the lines the selected conversation covers
        if here?.kind == .thread, let t = here?.id.flatMap({ app.store.view(CanopyCore.Thread.self, $0) }), let l = t.local, let s = l.startLine {
            marks.range = (t.path, t.side, s, l.line)
        } else if let r = pg.range, let s = r.startLine {
            marks.range = (r.path, r.side, s, r.line)
        }
        for v in pg.views { for h in v.seenHunks { marks.seen.insert("\(v.file.path)#\(h)") } }
        if focused && app.keys.mode == .select { marks.selection = Set(app.selection) }
        return CanvasView(handle: pg.diffCanvas, segments: ReviewDocument.segments(pg, app, colors), marks: marks, scrollTick: pg.cursorMoved,
                          onClick: { stop, shift in
                              app.focus(pane: reviewDiffPane)
                              app.runner.dispatch("review.cursor.set", via: .click, target: stop, arg: shift)
                          },
                          onPointer: { info, offset, right in
                              let l: DiffLine? = {
                                  guard let i = pg.stopIndex[info.stop ?? ""], let row = pg.stops[i].row else { return nil }
                                  return info.splitCol > 0 ? (right ? row.right : row.left) : (row.right ?? row.left)
                              }()
                              guard let l else { return }
                              let old = l.kind == .del || (info.splitCol > 0 && !right)
                              if let p = CodeLookup.position(path: info.path, line: (old ? l.old : l.new) ?? 1, text: l.text, at: offset, side: old ? "old" : "new") {
                                  pg.pointer = (p, pg.cursorMoved, pg.here?.key)
                              }
                          })
            .background(GeometryReader { g in
                Color.clear.onAppear { measure(pg, g.size.width) }.onChange(of: g.size.width) { _, w in measure(pg, w) }
            })
    }

    /// Characters across the diff, rounded down to an even count so a resize by a pixel doesn't relayout.
    private func measure(_ pg: ReviewPageState, _ width: CGFloat) {
        let cols = Int((width - 24) / DocFont.charWidth) & ~1
        if cols != pg.diffColumns { pg.diffColumns = cols }
    }

    @ViewBuilder private func pop(_ pg: ReviewPageState) -> some View {
        if CodeLookup.of(app).pop != nil {
            let r = pg.here.flatMap { pg.diffCanvas.canvas.visibleRect(of: $0.key) } ?? CGRect(x: 0, y: 40, width: 0, height: 0)
            TypesPopView().offset(x: 120, y: min(max(8, r.maxY + 4), 600))
        }
    }
}

/// A place outside the diff, open beside it at the commit it was found at (side.ts + CodePane.tsx):
/// its own pane, so j/k walk it and g d keeps going from wherever it lands.
private struct SidePane: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        if let l = pg.side {
            CodePaneView(handle: pg.sideCanvas, pane: reviewCodePane, path: l.path, refLabel: l.sha, text: pg.sideText,
                         lit: l.line...max(l.line, l.end ?? l.line), repo: l.repo, sha: l.sha, close: "review.side.close")
        }
    }
}

/// One file at one commit, its lit lines scrolled to (CodePane.tsx) — the review page's side pane
/// and the Tutor's pinned code. Its rows are "s:<line>" in pane `pane` (list them in your surface's
/// `panes()` so j/k walk it); the cursor is that pane's. Ask about the cursor line with CodeLookup:
/// `CodeLookup.position(path:line:text:)` + `.commit(repo:sha:)`.
public struct CodePaneView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let handle: CanvasHandle
    let pane: String
    let path: String
    let refLabel: String
    let text: String?
    var err: String?
    let lit: ClosedRange<Int>?
    let repo: String
    let sha: String
    /// the command that closes it (its ✕), if it can be closed
    var close: String?

    public init(handle: CanvasHandle, pane: String, path: String, refLabel: String, text: String?, err: String? = nil, lit: ClosedRange<Int>?, repo: String, sha: String, close: String? = nil) {
        self.handle = handle; self.pane = pane; self.path = path; self.refLabel = refLabel; self.text = text; self.err = err
        self.lit = lit; self.repo = repo; self.sha = sha; self.close = close
    }

    public var body: some View {
        let focused = app.isFocused(pane)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(path).foregroundStyle(theme.inkDim).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("\(lit.map { "L\($0.lowerBound)–\($0.upperBound) · " } ?? "")\(String(refLabel.prefix(10)))").foregroundStyle(theme.inkFaint)
                if let close {
                    Button("✕") { app.runner.dispatch(close, via: .click) }.buttonStyle(.plain).foregroundStyle(theme.inkFaint)
                        .labelTarget(pane: "\(pane).close", key: "close", title: "close", run: RouteTo(close))
                }
            }
            .font(Theme.text(11)).padding(.horizontal, 12).padding(.vertical, 6).background(theme.vellumRaise)
            if let err {
                Text(err).foregroundStyle(theme.del).padding(12)
            } else if let text {
                let lines = text.hasSuffix("\n") ? Array(text.components(separatedBy: "\n").dropLast()) : text.components(separatedBy: "\n")
                let c = CanvasColors(theme)
                let cursor = app.cursors["\(app.router.surface.id)/\(pane)"] ?? lit.map { "s:\($0.lowerBound)" }
                CanvasView(handle: handle, segments: [Segment(key: "code|\(repo)|\(sha)|\(path)|\(lines.count)") { ReviewDocument.code(lines, path: path, c) }],
                           marks: CanvasMarks(cursor: cursor, lit: lit, focused: focused),
                           centerOn: lit.map { "s:\($0.lowerBound)|\(repo)|\(sha)|\(path)" },
                           onClick: { stop, _ in app.focus(pane: pane); app.setCursor(stop) })
            } else {
                Text("reading \(path)…").foregroundStyle(theme.inkFaint).padding(12)
            }
            Spacer(minLength: 0)
        }
        .background(theme.diffBg)
        .paneRing(pane)
    }
}
