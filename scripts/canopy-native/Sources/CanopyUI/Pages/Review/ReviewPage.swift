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
                        if pg.showsOutline { Color.clear.frame(width: pg.outlineReserve(app.pane?.id)) }
                        VStack(alignment: .leading, spacing: 8) {
                            if let sha = ShipState.of(app).commitScope {
                                CommitHead(branchID: pg.id, sha: sha).padding(.horizontal, 16).padding(.top, 4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            DiffPane(empty: pg.base == .outgoing ? "nothing to push" : "no changes").frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                        .padding(.leading, pg.showsOutline ? 0 : 12)
                        if pg.side != nil { SidePane().frame(width: 520) }
                    }
                    .overlay(alignment: .topLeading) {
                        if pg.showsOutline {
                            let strip = pg.outlineIsStrip(app.pane?.id)
                            Outline(strip: strip)
                                .frame(width: strip ? pg.stripWidth : pg.outlineWidth)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(theme.vellumNight)
                                .overlay(alignment: .trailing) {
                                    if !strip && pg.showsTree { theme.vellumEdge.frame(width: 1) }
                                }
                        }
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
        .overlay { if let h = pg.helix, h.whole, let dir = h.dir { HelixCover(open: h, dir: dir) } }
        .onAppear { pg.sync() }
        .task(id: "\(pg.id)@\(pg.tip)") { pg.warmHelix(app) }
    }
}

/// What the change is, and what's left to do with it: the title, the ship strip, and only the
/// conversation's states that wait on you.
private struct ReviewHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        let pg = ReviewPageState.of(app)
        let c = pg.conv
        let b = pg.branch
        VStack(alignment: .leading, spacing: 4) {
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
                if pg.integration == nil { ShipStripView(branchID: pg.id) }
            }
            if let c, !waiting(c, pg).isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ForEach(waiting(c, pg), id: \.self) { Text($0) }
                }
                .font(Theme.text(11.5)).foregroundStyle(theme.goldLeaf).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
    }

    private func waiting(_ c: Conv, _ pg: ReviewPageState) -> [String] {
        var out: [String] = []
        if c.mapping == .behind { out.append("\(c.behind) on GitHub not here") }
        let waiting = pg.items.filter { $0.state == .waiting }.count
        if waiting > 0 { out.append("\(waiting) waiting to push") }
        let drafts = pg.items.filter { $0.state == .draft }.count
        if drafts > 0 { out.append("\(drafts) draft\(drafts == 1 ? "" : "s")") }
        if let n = c.pending?.count, n > 0 { out.append("\(n) pending") }
        return out
    }
}


/// The file tree: a pane of the diff's files with viewed boxes, its filter on top while finding.
/// The review's table of contents, down the left margin: the branch's commits oldest first with
/// what they land as at the foot (the cursor there scopes the diff), then its files when there are
/// several. Two panes, one above the other: "history" and "files".
private struct Outline: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// the diff has focus: only the files, by name
    let strip: Bool

    var body: some View {
        let pg = ReviewPageState.of(app)
        VStack(alignment: .leading, spacing: 14) {
            if pg.showsHistory && !strip { HistoryList(branchID: pg.id).fixedSize(horizontal: false, vertical: true) }
            if pg.showsTree { FileTree(strip: strip) }
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
    let strip: Bool

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
                        let tint = current == path ? theme.goldLeaf : v.viewed ? theme.inkFaint : theme.ink
                        if strip {
                            Text(path.split(separator: "/").last.map(String.init) ?? path).foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
                        } else {
                            PathText(path: path, tint: tint)
                        }
                        Spacer(minLength: 4)
                        if v.open > 0 { Text("\(v.open)").foregroundStyle(theme.ember) }
                        if !strip {
                            Text("+\(v.file.add)").foregroundStyle(theme.add)
                            Text("−\(v.file.del)").foregroundStyle(theme.del)
                        }
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

/// `o`: Helix over the whole page — the header, the outline and the diff — not boxed inside the diff.
private struct HelixCover: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let open: HelixOpen
    let dir: String

    var body: some View {
        let pg = ReviewPageState.of(app)
        HelixHalf(open: open, dir: dir, colors: CanvasColors(theme), moved: { pg.helixAt = ($0, $1) }) { pg.landHelix(app) }
            .id("\(dir)|\(open.path)")
            .background(theme.vellumNight)
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

    /// Helix over the diff: `o` covers it all; `i` starts where the split puts the new half, so the
    /// old half stays to read against.
    @ViewBuilder private func helix(_ pg: ReviewPageState) -> some View {
        if let h = pg.helix, !h.whole, let dir = h.dir {
            HelixHalf(open: h, dir: dir, colors: CanvasColors(theme), moved: { pg.helixAt = ($0, $1) }) { pg.landHelix(app) }
                .id("\(dir)|\(h.path)")
                .padding(.leading, CGFloat(pg.splitWidth(h.path) + 7) * DocFont.charWidth + 1)
        }
    }

    private func canvas(_ pg: ReviewPageState) -> some View {
        let colors = CanvasColors(theme)
        let here = pg.here
        let focused = app.isFocused(reviewDiffPane)
        var marks = CanvasMarks(cursor: here?.key, column: pg.column, focused: focused)
        for (row, hs) in PageSearch.of(app).hitsByRow(app, pane: reviewDiffPane) {
            let right = pg.splitWidth(pg.stopIndex[row].map { pg.stops[$0].path }) + 13
            marks.hits[row] = hs.map { h in let o = h.field == 0 ? right : ReviewDocument.codeStart; return (o + h.at.lowerBound)..<(o + h.at.upperBound) }
        }
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
                          onClickAt: { stop, side, at in pg.click(stop, side: side, at: at) },
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
                          },
                          onViewed: { path in
                              app.focus(pane: reviewDiffPane)
                              app.runner.dispatch("review.viewed.file", via: .click, arg: path)
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
                         lit: l.line...max(l.line, l.end ?? l.line), repo: l.repo, sha: l.sha, close: "review.side.close",
                         word: pg.sideHereWord.flatMap { w in pg.sideWord.map { ($0.line, w) } }, searched: true)
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
    /// the name `w` / `b` are on: its line and UTF-16 range in that line
    var word: (line: Int, at: Range<Int>)?
    /// `/` searches its lines' text (its surface's `searchFields`), so its matches light up
    var searched = false

    public init(handle: CanvasHandle, pane: String, path: String, refLabel: String, text: String?, err: String? = nil, lit: ClosedRange<Int>?, repo: String, sha: String, close: String? = nil,
                word: (line: Int, at: Range<Int>)? = nil, searched: Bool = false) {
        self.handle = handle; self.pane = pane; self.path = path; self.refLabel = refLabel; self.text = text; self.err = err
        self.lit = lit; self.repo = repo; self.sha = sha; self.close = close; self.word = word; self.searched = searched
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
                           marks: marks(cursor: cursor, focused: focused),
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

    private func marks(cursor: String?, focused: Bool) -> CanvasMarks {
        var m = CanvasMarks(cursor: cursor, lit: lit, focused: focused)
        if let word { m.word = ("s:\(word.line)", (ReviewDocument.codeStart + word.at.lowerBound)..<(ReviewDocument.codeStart + word.at.upperBound)) }
        for (row, hs) in searched ? PageSearch.of(app).hitsByRow(app, pane: pane) : [:] {
            m.hits[row] = hs.map { (ReviewDocument.codeStart + $0.at.lowerBound)..<(ReviewDocument.codeStart + $0.at.upperBound) }
        }
        if focused && app.keys.mode == .select { m.selection = Set(app.selection) }
        return m
    }
}
