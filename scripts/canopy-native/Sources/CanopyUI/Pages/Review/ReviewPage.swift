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
                        FileTree().frame(width: 280)
                        DiffPane(empty: pg.base == .outgoing ? "nothing to push" : "no changes").frame(maxWidth: .infinity, maxHeight: .infinity)
                        if pg.side != nil { SidePane().frame(width: 520) }
                    }
                }
            }
        }
        .overlay { if app.keys.layer == .map { MapOverlay() } }
        .onAppear { pg.sync() }
    }
}

/// The title, the ship strip, who's reviewing, and the tabs.
private struct ReviewHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        let c = pg.conv
        let b = pg.branch
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let c {
                    Text(c.title).font(Theme.display(22)).foregroundStyle(theme.ink).lineLimit(1)
                    Text("#" + String(c.number)).foregroundStyle(theme.inkFaint)
                } else if let p = pg.integration {
                    Text("✦ \(app.store.view(Project.self, p)?.name ?? p) — every branch merged onto main").font(Theme.display(22)).foregroundStyle(theme.ink)
                } else {
                    Text(b.map { $0.description.isEmpty ? $0.name : $0.description } ?? pg.target?.name ?? "").font(Theme.display(22)).foregroundStyle(theme.ink).lineLimit(1)
                }
                Spacer(minLength: 24)
                if pg.integration == nil {
                    LoopStripView(branchID: pg.id, words: loopWords(pg.id), size: 11)
                        .task(id: b.map { "\($0.id)@\($0.tip)" }) { WordsState.of(app).load(app, pg.id) }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let c {
                    Text("→ \(c.base)")
                    Text(c.author)
                    ForEach(latest(c), id: \.0) { who, st in
                        Text("\(st == "APPROVED" ? "✓" : "✗") \(who)").foregroundStyle(st == "APPROVED" ? theme.patina : theme.ember)
                    }
                    if c.mapping == .behind {
                        Text("\(c.behind) commit\(c.behind == 1 ? "" : "s") on GitHub not here — pull to review what's there").foregroundStyle(theme.ember)
                    }
                    let waiting = pg.items.filter { $0.state == .waiting }.count
                    if waiting > 0 { Text("\(waiting) draft\(waiting == 1 ? " waits" : "s wait") for a push").foregroundStyle(theme.goldLeaf) }
                    let drafts = pg.items.filter { $0.state == .draft }.count
                    if drafts > 0 { Text("\(drafts) draft\(drafts == 1 ? "" : "s") · \(app.registry.keyOf("review.send.all")) sends").foregroundStyle(theme.goldLeaf) }
                    if let n = c.pending?.count, n > 0 { Text("\(n) pending · \(app.registry.keyOf("review.finish")) submit").foregroundStyle(theme.goldLeaf) }
                } else if app.store.ready, b?.pushed != .local {
                    Text(noPR(pg)).foregroundStyle(theme.inkFaint)
                }
                if pg.integration == nil { ShipStripView(branchID: pg.id) }
            }
            .font(Theme.mono(11)).foregroundStyle(theme.inkFaint)
            Tabs()
        }
        .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 10)
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

/// conversation · commits · files, each a label target; the base and the viewed count on the right.
private struct Tabs: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        let c = pg.conv
        let b = pg.branch
        let openThreads = pg.threads.filter { !$0.resolved && !$0.outdated }.count
        HStack(spacing: 16) {
            tab("conversation", count: "\((c?.comments.count ?? 0) + (c?.reviews.filter { !$0.body.isEmpty }.count ?? 0) + pg.threads.count)")
            tab("commits", count: b.map { "\($0.commits)" } ?? "")
            tab("files", count: "\(pg.branchFiles.count)")
            Spacer()
            if pg.tab == "files" && pg.integration == nil {
                Text("vs").foregroundStyle(theme.inkFaint)
                Button(pg.base.word) { app.runner.dispatch("review.base.next", via: .click) }
                    .buttonStyle(.plain).foregroundStyle(theme.goldLeaf)
                    .labelTarget(pane: "tabs", key: "base", title: "base", run: RouteTo("review.base.next"))
            }
            if openThreads > 0 { Text("\(openThreads) open").foregroundStyle(theme.ember) }
            Text("\(pg.branchViewed)/\(pg.branchFiles.count) viewed").foregroundStyle(theme.inkFaint)
        }
        .font(Theme.mono(12))
        .padding(.top, 6)
    }

    @ViewBuilder private func tab(_ name: String, count: String, extra: String? = nil) -> some View {
        let pg = ReviewPageState.of(app)
        let on = pg.tab == name
        Button { app.runner.dispatch("review.tab.\(name)", via: .click) } label: {
            HStack(spacing: 5) {
                Text(name).foregroundStyle(on ? theme.goldLeaf : theme.inkDim)
                Text(count).foregroundStyle(theme.inkFaint)
                if let extra { Text(extra).foregroundStyle(theme.goldLeaf) }
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) { if on { theme.goldLeaf.frame(height: 1.5).offset(y: 2) } }
        }
        .buttonStyle(.plain)
        .labelTarget(pane: "tabs", key: "tab:\(name)", title: name, run: RouteTo("review.tab.\(name)"))
    }
}

/// The file tree: a pane of the diff's files with viewed boxes, its filter on top while finding.
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
                .font(Theme.mono(12)).padding(6).background(theme.vellumRaise)
            }
            PaneList(pane: reviewTreePane, rows: ReviewPage.treeRows(pg)) { key, _ in
                let path = String(key.dropFirst(2))
                if let v = views[path] {
                    HStack(spacing: 6) {
                        Text(v.viewed ? "☑" : v.seen > 0 ? "◪" : "☐").foregroundStyle(v.viewed ? theme.patina : theme.inkFaint)
                        Text(shortPath(path)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(current == path ? theme.goldLeaf : v.viewed ? theme.inkFaint : theme.ink)
                        Spacer(minLength: 4)
                        if v.open > 0 { Text("\(v.open)").foregroundStyle(theme.ember) }
                        Text("+\(v.file.add)").foregroundStyle(theme.add)
                        Text("−\(v.file.del)").foregroundStyle(theme.del)
                    }
                    .font(Theme.mono(11.5))
                    .help(path)
                }
            }
        }
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
        .overlay { Rectangle().stroke(app.isFocused(reviewDiffPane) ? theme.goldDeep : theme.rule.opacity(0.5), lineWidth: 1) }
        .overlay(alignment: .topLeading) { pop(pg) }
    }

    private func canvas(_ pg: ReviewPageState) -> some View {
        let colors = CanvasColors(theme)
        let here = pg.here
        let focused = app.isFocused(reviewDiffPane)
        var marks = CanvasMarks(cursor: here?.key, column: pg.column, focused: focused)
        if let w = pg.hereWord, let k = here?.key, let row = here?.row {
            let start = sideLine(row, prefer: pg.column).side == .left ? 6 : pg.splitWidth + 13
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
            .font(Theme.mono(11)).padding(.horizontal, 12).padding(.vertical, 6).background(theme.vellumRaise)
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
        .overlay { Rectangle().stroke(focused ? theme.goldDeep : theme.rule.opacity(0.5), lineWidth: 1) }
    }
}
