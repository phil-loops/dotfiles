import CanopyCore
import Foundation
import Observation
import SwiftUI

// The review page's state (review/page.ts): which branch, its diff (lazy, cached by tip and base),
// and the stops the cursor walks — every diff row, and under it the threads and pending comments
// anchored there — plus the folds, the overlays and the side code pane the review commands move.
// Views and commands both read it. One per window: `ReviewPageState.of(app)`.
//
// The diff's cursor IS the shell's pane cursor (PORTING §7): the stops are the rows of the "diff"
// pane, so j/k, gg/G, C-d/C-u, v-select, the statusline and the app-wide jumplist all work on them.

/// What the files tab diffs against (page.ts Base), riding the address as ?base=.
public enum ReviewBase: String, CaseIterable, Sendable {
    case parent = "", main, outgoing
    public var word: String { self == .parent ? "parent" : rawValue }
}

/// One file of GET /node or /commit-diff.
public struct NodeFile: Codable, Equatable, Sendable {
    public var path: String
    public var add: Int
    public var del: Int
    public var patch: String
    public var wsOnly: Bool?
}

/// GET /node?branch=[&base=] (API.md §4).
public struct NodePayload: Codable, Equatable, Sendable {
    public var branch: String?
    public var baseSha: String?
    public var worktree: String?
    public var files: [NodeFile]
}

/// A ledger item GitHub doesn't show yet (drafts, waiting, sending, lost): the page draws these; a
/// pending or submitted one is drawn from GitHub's own copy in the thread.
func isLocal(_ i: DraftItem) -> Bool { i.state != .pending && i.state != .submitted }

/// One file of the diff as the page shows it (page.ts FileView).
public struct FileView: Equatable {
    public var file: FileDiff
    public var rows: [DiffRow]
    public var threadsAt: [String: [CanopyCore.Thread]]
    public var pendingAt: [String: [DraftItem]]
    /// threads whose line isn't a row here (outdated, or moved out of the diff)
    public var aside: [CanopyCore.Thread]
    public var open: Int
    /// every change block viewed
    public var viewed: Bool
    public var blocks: [Block]
    /// how many of its blocks are viewed, and how many flagged
    public var seen: Int
    public var flagged: Int = 0
    /// each changed row's block (an index into `blocks`), by row key
    public var rowBlock: [String: Int] = [:]
    /// each block's mark, in `blocks` order
    public var marks: [Mark] = []
    /// unchanged lines the diff still hides (each a cursor stop; ↵ shows more)
    public var gaps: [Gap]

    /// Where a row's threads and pending comments render.
    public func at(_ r: DiffRow) -> (threads: [CanopyCore.Thread], pending: [DraftItem]) {
        let as_ = rowAnchors(r)
        return (as_.flatMap { threadsAt[$0] ?? [] }, as_.flatMap { pendingAt[$0] ?? [] })
    }
}

/// A place the cursor stops (page.ts Stop): a file's header, a diff row, a conversation, a pending
/// comment, or a run of hidden lines. The key is the pane row key.
public struct Stop: Equatable {
    public enum Kind: String { case file, line, thread, pending, gap }
    public var key: String
    public var kind: Kind
    public var path: String
    public var row: DiffRow?
    /// a thread's id or a pending item's key
    public var id: String?
    /// a gap's place
    public var at: Int?
}

/// The commentable range under the cursor (page.ts range).
public struct ReviewLineRange: Equatable, Sendable {
    public var path: String
    public var side: Side
    public var line: Int
    public var startLine: Int?
}

/// The side and line number a row is commented on: the `prefer`red half when the row has a line
/// there, else the half it has. The old half counts only where it differs from the new — a removed
/// line — so an unchanged line is always read, and commented on, on its new half.
public func sideLine(_ r: DiffRow, prefer: Side = .right) -> (side: Side, line: Int) {
    if prefer == .left, let o = r.left?.old, r.left?.kind == .del || r.right?.new == nil { return (.left, o) }
    if let n = r.right?.new { return (.right, n) }
    return (.left, r.left?.old ?? 0)
}

/// A row that changed: either half added or removed.
public func changed(_ r: DiffRow) -> Bool { r.left?.kind != .ctx || r.right?.kind != .ctx }

/// What Phil has made of a change block: not read yet, read, or read and flagged to come back to.
/// The raw values are the server's states (POST /viewed).
public enum Mark: String, Equatable, Sendable { case unread = "none", viewed, flagged }

extension FileView {
    /// The mark on a changed row's block; nil for an unchanged row.
    public func mark(of r: DiffRow) -> Mark? { rowBlock[r.key].map { marks[$0] } }
}

/// Each changed line's block as an anchor ("L:<old>" / "R:<new>") → index into `blocksOf(f)`, walking the
/// hunks the way blocksOf does — line numbers, so rows from a diff with more context still find their block.
public func blockAnchors(_ f: FileDiff) -> [String: Int] {
    var out: [String: Int] = [:]
    var b = -1
    for h in f.hunks {
        var inRun = false
        for l in h.lines {
            if l.kind == .ctx { inRun = false; continue }
            if !inRun { b += 1; inRun = true }
            out[anchorOf(l)] = b
        }
    }
    return out
}

public let reviewDiffPane = "diff"
public let reviewTreePane = "files"
/// the branch's line in the header: its points, the cursor `, h` puts there
public let reviewLinePane = "line"
public let reviewCodePane = "code"

@MainActor
@Observable
public final class ReviewPageState: ShipHost {
    @ObservationIgnored weak var app: AppModel?

    /// The diff's canvas and the side pane's, kept here so commands and the label layer can reach them.
    @ObservationIgnored let diffCanvas = CanvasHandle()
    /// The focused file's canvas (else the first window's).
    var sideCanvas: CanvasHandle { (code ?? windows[0]).canvas }

    public static func of(_ app: AppModel) -> ReviewPageState { app.state { ReviewPageState(app) } }

    init(_ app: AppModel) {
        self.app = app
        _ = app.store.onChange { [weak self] in self?.storeMoved() }
    }

    // ── the page's own state ──

    /// "conversation" | "commits" | "files" (ShipHost's tab)
    public var tab = "files" { didSet { if tab != oldValue { tabMoved(oldValue) } } }
    /// Diffs are always side by side.
    public let split = true
    /// How many characters fit across the diff, so a split line gives each half the same width (0: not measured yet).
    public var diffColumns = 0
    /// A branch with more than one commit can scope its diff to one of them (the header's chip).
    public var scopesCommits: Bool { integration == nil && (branch?.commits ?? 0) > 1 }
    /// The left margin is the files, when there's more than one to move between (or a filter typed
    /// into it). Its width never follows focus: what the diff covers is the header's, not the margin's.
    public var showsTree: Bool { views.count > 1 || !filter.isEmpty }
    /// As wide as the longest path needs, within reason; a long folder gives way from its start.
    public var treeWidth: CGFloat {
        let longest = files.map(\.path.count).max() ?? 20
        return min(260, max(180, CGFloat(longest) * 6.6 + 80))
    }
    /// Characters the old half of a split line gets in this file: none for a new file and all of it
    /// for a deleted one, which have only one side to show; else half, since both halves carry the
    /// same context lines and a narrower one would wrap them.
    public func splitWidth(_ path: String?) -> Int {
        let usable = diffColumns > 0 ? diffColumns - 13 : 120
        switch files.first(where: { $0.path == path })?.status {
        case .added: return 0
        case .deleted: return usable
        default: return max(24, usable / 2)
        }
    }
    /// The cursor in the code: its row, half and UTF-16 range in that half's text (one character). It
    /// counts only while the cursor is still on that row and half.
    public var word: (key: String, side: Side, at: Range<Int>)?
    /// The selected name, when it's still under the cursor.
    public var hereWord: Range<Int>? {
        guard let w = word, let h = here, h.key == w.key, let row = h.row, sideLine(row, prefer: column).side == w.side else { return nil }
        return w.at
    }
    /// The name `w` / `b` put the cursor on in the open file: its line and UTF-16 range.
    public var sideWord: (line: Int, at: Range<Int>)? {
        get { (code ?? windows.first { $0.doc != nil })?.word }
        set { (code ?? windows.first { $0.doc != nil })?.word = newValue }
    }
    /// The focused file's selected name, when the cursor is still on its line.
    public var sideHereWord: Range<Int>? {
        guard let c = code, let w = c.word, let app, RowKey.id(app.selected, "s").flatMap(Int.init) == w.line else { return nil }
        return w.at
    }
    /// The repo's GitHub page per repo ("https://github.com/<owner>/<name>"), once origin is read.
    @ObservationIgnored var githubWebs: [String: String] = [:]
    /// How the GitHub page is found: origin's URL in the branch's checkout (the keytutor and tests stub it).
    @ObservationIgnored public var githubWeb: ((AppModel) async -> String?)?
    /// Helix open in the diff, from `i` or `o` until it quits.
    public var helix: HelixOpen?
    /// "<branch>@<tip>" → its Helix checkout, made ahead of the first `i` or `o`
    var helixDirs: [String: String] = [:]
    /// The half of the split the cursor reads, kept as it moves up and down; `h` / `l` switch it.
    public var column: Side = .right
    public var showOutdated = false
    /// where `x` dropped its mark (the other end of a range comment)
    public var mark: String?
    /// block key → its mark, ahead of the server's copy while a write is in flight
    public var viewedOverride: [String: Mark] = [:]
    /// the file tree's filter (space f), and the page search (/)
    public var filter = ""
    public var search = ""
    /// the forest map overlay is up (space m) — its layer's cursor
    public var mapIndex = 0
    /// what the diff covers when it isn't a base's whole stretch: one commit ("sha") or a run of
    /// them ("from..to", both ends included) — the branch line's lit stretch (ReviewLine). Its files beside it.
    public private(set) var commitScope: String?
    public private(set) var commitFiles: (sha: String, files: [NodeFile])?

    // ── the diff ──

    public private(set) var payload: (key: String, data: NodePayload)?
    public private(set) var loadErr: String?
    /// bumped whenever a diff lands (the memos key on it)
    private(set) var payloadGen = 0
    @ObservationIgnored private var cache: [String: NodePayload] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var prepared = ""

    /// Revealed context per file, for one diff (the key): the new file read once, how much each gap shows.
    struct Context: Equatable { var lines: [String]?; var reveal: [Int: Int] }
    private(set) var context: (key: String, files: [String: Context]) = ("", [:]) { didSet { contextGen &+= 1 } }
    private(set) var contextGen = 0

    /// A J/K hop: the tab to keep and the file to land on once the neighbour's diff is here.
    @ObservationIgnored var carry: (id: String, tab: String, path: String?)?
    /// A jumplist entry to finish restoring once its diff is here.
    @ObservationIgnored var pendingCursor: (id: String, key: String)?
    /// An address's line on the tip (`?file=…&line=…`), to find once the diff is here.
    @ObservationIgnored var pendingLoc: (id: String, loc: Loc)?
    /// A restored place's viewport row, for whichever of those lands the cursor.
    @ObservationIgnored var pendingRow: (id: String, row: Int)?
    /// Where Helix's cursor was when it quit, to put the diff's cursor on once the diff (perhaps with Helix's commit) is here.
    @ObservationIgnored var pendingNear: (id: String, path: String, line: Int)?
    @ObservationIgnored var pendingFlag: (id: String, flag: Flag)?
    /// Helix's cursor as its status line last showed it, while it's open.
    @ObservationIgnored var helixAt: (path: String, line: Int)?
    /// The branch the page last showed (a new one starts fresh).
    @ObservationIgnored private var shownID = ""
    /// This branch's diff is here (not the last page's, still showing while this one comes).
    var diffHere: Bool { payload != nil && shownID == id }

    // ── the windows (ReviewWindows.swift): each shows the diff or one file at one commit (Helix's views) ──

    /// In reading order; the diff shows in at most one.
    public internal(set) var windows: [ReviewWindow] = [ReviewWindow(id: 1, column: 0)]
    /// The focused file (else the first window's file); nil: no window shows one.
    public var side: Loc? { (code ?? windows.first { $0.doc != nil })?.doc }
    public var sideText: String? { (code ?? windows.first { $0.doc != nil })?.text }
    @ObservationIgnored private var srcCache: [String: [String]] = [:]
    func cachedLines(_ k: String) -> [String]? { srcCache[k] }

    // ── the target ──

    public struct Target: Equatable { public var repo: String; public var name: String; public var id: String }

    public var target: Target? {
        guard let app, case .review(let repo, let name, _) = app.router.route, !repo.isEmpty else { return nil }
        return Target(repo: repo, name: name, id: "\(repo):\(name)")
    }

    public var id: String { target?.id ?? "" }
    public var branch: Branch? { app?.store.view(Branch.self, id) }
    public var conv: Conv? { app?.store.table(Conv.self)[id] }
    public var draft: Draft? { app?.store.view(Draft.self, id) }
    public var tip: String { branch?.tip ?? conv?.tip ?? "" }

    /// The forest whose whole diff this page shows (its integration ref), else nil for a branch.
    public var integration: String? {
        guard let t = target, let p = Route.integrationOf(t.name), app?.store.view(Project.self, "\(t.repo):\(p)") != nil else { return nil }
        return "\(t.repo):\(p)"
    }

    /// What the diff is read at: the tip, or for an integration its forest's tips.
    var at: String {
        if let pid = integration, let app {
            return app.store.list(Branch.self).filter { $0.project == pid }.map(\.tip).joined(separator: ",")
        }
        return tip
    }

    public var base: ReviewBase {
        guard let app, case .review(_, _, let b) = app.router.route else { return .parent }
        return ReviewBase(rawValue: b) ?? .parent
    }

    /// The address carries the base, so a link reproduces the view (history.replaceState).
    public func setBase(_ b: ReviewBase) {
        guard let app, case .review(let r, let n, _) = app.router.route else { return }
        app.router.replace(.review(repo: r, branch: n, base: b.rawValue))
    }

    /// The base as sent: outgoing is origin's copy, which a branch never pushed doesn't have.
    func baseRef(_ name: String) -> String {
        switch base {
        case .main: return "main"
        case .outgoing: return branch?.pushed != .local ? "origin/\(name)" : ""
        case .parent: return ""
        }
    }

    public var keyOf: String { "\(id)@\(at)|\(baseRef(target?.name ?? ""))" }
    public var baseSha: String { payload?.data.baseSha ?? "" }
    public var scoped: Bool { commitScope != nil }
    /// the commit the scoped diff ends on: its new side is that commit's tree
    public var scopeEnd: String? { commitScope.map { ReviewLine.ends($0).to } }

    /// The branch's line, once its history is read; none on a forest's integration page.
    public var line: ReviewLine? {
        guard integration == nil, let app, let b = branch, let rows = ShipState.of(app).historyRows(id) else { return nil }
        return ReviewLine(parentIsMain: b.parent.isEmpty || b.parent == "main", commits: rows)
    }
    /// The stretch the diff covers on the line.
    public var lit: (lo: Int, hi: Int)? { line?.lit(base: base, scope: commitScope) }
    /// the point ↵ picked first on the line, waiting for the other end
    public var lineAnchor: Int?

    /// Make the diff cover what was chosen on the line; a refusal says why and changes nothing.
    public func apply(_ c: ReviewLine.Choice) throws {
        switch c {
        case .refuse(let why): throw Refusal(why)
        case .base(let b):
            if commitScope != nil { commitScopeChanged(nil) }
            if b != base { setBase(b) }
        case .commits:
            if commitScope != c.scope { commitScopeChanged(c.scope) }
        }
        tab = "files"
    }

    func repoPath(_ p: String) -> String { app?.transport.atRepo(target?.repo ?? "", p) ?? p }

    // ── loading ──

    /// Bring the page up to its address: a new branch starts fresh, a new tip or base reads its diff
    /// (the old one stays up until the new one lands). Views call it on appear and on change.
    public func sync() {
        guard let t = target else { return }
        arrive()
        // the header's line is the page's: its commits load with the diff (a no-op once read at this tip)
        if integration == nil, let app { ShipState.of(app).loadHistory(app, id) }
        let key = keyOf
        if payload?.key == key { return }
        if let hit = cache[key] { return land(key, hit) }
        guard !loading.contains(key) else { return }
        loading.insert(key)
        let b = baseRef(t.name)
        let path = repoPath("/node?branch=\(t.name.uriComponent)\(b.isEmpty ? "" : "&base=\(b.uriComponent)")")
        Task { @MainActor [weak self] in
            guard let self, let app = self.app else { return }
            defer { self.loading.remove(key) }
            do {
                let data = try await app.transport.getJSON(path, as: NodePayload.self)
                self.cache[key] = data
                if self.keyOf == key { self.land(key, data) }
            } catch {
                if self.keyOf == key { self.loadErr = String(describing: error) }
            }
        }
    }

    /// The page is on a new branch: start it fresh, once, whichever comes first — the view's sync or
    /// a prefetched diff landing.
    private func arrive() {
        guard let t = target, shownID != t.id else { return }
        let first = shownID.isEmpty
        shownID = t.id
        if !first || payload != nil { resetForNewBranch(t.id) }
    }

    /// Take a diff as read (tests hand one in directly).
    public func land(_ key: String, _ data: NodePayload) {
        arrive()
        cache[key] = data
        payload = (key, data)
        payloadGen &+= 1
        parsed = nil
        rowCache = [:]
        blockCache = [:]
        loadErr = nil
        prepareTypes()
        settleCursor()
        warmNeighbours()
    }

    private func resetForNewBranch(_ newID: String) {
        payload = nil
        loadErr = nil
        mark = nil
        viewedOverride = [:]
        commitScope = nil
        commitFiles = nil
        windows = [ReviewWindow(id: 1, column: 0)]
        if let c = carry, c.id == newID { tab = c.tab } else { carry = nil; tab = "files" }
        guard let app else { return }
        // a jumplist entry being restored already put its cursor
        if pendingCursor?.id == newID || pendingLoc?.id == newID || pendingFlag?.id == newID { return }
        let was = app.pane?.id
        app.focus(pane: reviewDiffPane)
        app.setCursor(nil)
        if let was, was == reviewTreePane { app.focus(pane: was) }
    }

    /// Once a diff is here: put the cursor where a J/K hop or a jumplist entry wants it, or on the
    /// first line (page.ts here()'s default) when it has none.
    private func settleCursor() {
        // a restored commit's place waits for that commit's diff, not the branch's
        if let c = commitScope, commitFiles?.sha != c, pendingCursor?.id == id || pendingLoc?.id == id { return }
        let s = stops
        if let n = pendingNear, n.id == id, let k = stopNear(path: n.path, line: n.line) {
            pendingNear = nil
            return setCursor(k)
        }
        if let p = pendingFlag, p.id == id, let k = stopOf(block: p.flag.key, in: p.flag.path) ?? stopNear(path: p.flag.path, line: p.flag.line) {
            pendingFlag = nil
            return setCursor(k)
        }
        if let c = carry, c.id == id {
            carry = nil
            let path = c.path.flatMap { stopIndex["f|\($0)"] != nil ? $0 : nil } ?? stopFiles.first
            if let k = path.flatMap(landing(file:)) ?? s.first?.key { setCursor(k) }
            return
        }
        if let p = pendingCursor, p.id == id, stopIndex[p.key] != nil {
            pendingCursor = nil
            setCursor(p.key, focus: false)
            return takePendingRow()
        }
        if let p = pendingLoc, p.id == id {
            pendingLoc = nil
            open(p.loc)
            return takePendingRow()
        }
        // a page opening for the first time puts the keyboard in the diff
        let fresh = app?.focusedPane["review"] == nil
        if diffCursor == nil, let k = stopFiles.first.flatMap(landing(file:)) ?? s.first?.key { setCursor(k, focus: fresh) }
        else if fresh { app?.focus(pane: reviewDiffPane) }
    }

    /// Move the type trees to this tip (and the diff's base) while it's read, so the first K is warm.
    private func prepareTypes() {
        guard let app, let t = target, !tip.isEmpty else { return }
        let k = "\(t.id)@\(tip)|\(baseSha)"
        guard prepared != k else { return }
        prepared = k
        struct Prep: Encodable { var branch: String; var base: String? }
        let path = repoPath("/lsp/prepare")
        let body = Prep(branch: t.name, base: baseSha.isEmpty ? nil : baseSha)
        Task { _ = await app.transport.ask(path, body, as: JSONValue.self) }
    }

    /// Prefetch a branch's diff so opening it paints at once (page.ts warm).
    public func warm(repo: String, name: String, at: String) {
        let key = "\(repo):\(name)@\(at)|"
        guard cache[key] == nil, !loading.contains(key), let app else { return }
        loading.insert(key)
        let path = app.transport.atRepo(repo, "/node?branch=\(name.uriComponent)")
        Task { @MainActor [weak self] in
            defer { self?.loading.remove(key) }
            guard let self, let d = try? await app.transport.getJSON(path, as: NodePayload.self) else { return }
            self.cache[key] = d
            // the page may have moved here while this was in flight, and sync() skips a key that's loading
            if self.keyOf == key, self.payload?.key != key { self.land(key, d) }
        }
    }

    private func warmNeighbours() {
        guard base == .parent else { return }
        for d in [1, -1] { if let b = neighbour(d) { warm(repo: b.repo, name: b.name, at: b.tip) } }
    }

    /// The branch `d` steps along this one's forest in merge order (J/K), or nil at an end.
    public func neighbour(_ d: Int) -> Branch? {
        guard let app, let b = branch else { return nil }
        let order = app.store.list(Branch.self).filter { $0.project == b.project }.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
        guard let i = order.firstIndex(where: { $0.id == b.id }), order.indices.contains(i + d) else { return nil }
        return order[i + d]
    }

    // ── a stretch of commits ──

    /// ShipHost.commitScopeChanged: show one commit's diff or a run's ("from..to", GET /commit-diff),
    /// or the branch again.
    public func commitScopeChanged(_ sha: String?) {
        commitScope = sha
        lineAnchor = nil
        mark = nil
        let waiting = pendingCursor?.id == id || pendingLoc?.id == id
        if !waiting, let k = stopFiles.first.flatMap(landing(file:)) { setCursor(k, focus: false) }
        guard let sha, commitFiles?.sha != sha, let app else { return }
        let ends = ReviewLine.ends(sha)
        let path = repoPath("/commit-diff?sha=\(ends.to.uriComponent)" + (ends.from.map { "&from=\($0.uriComponent)" } ?? ""))
        Task { @MainActor [weak self] in
            struct CommitDiff: Decodable { var sha: String?; var files: [NodeFile] }
            guard let got = try? await app.transport.getJSON(path, as: CommitDiff.self), let self, self.commitScope == sha else { return }
            self.commitFiles = (sha, got.files)
            if self.pendingCursor?.id == self.id || self.pendingLoc?.id == self.id { return self.settleCursor() }
            if let k = self.stopFiles.first.flatMap(self.landing(file:)) { self.setCursor(k, focus: false) }
        }
    }

    /// Tests and the inline view hand a commit's files in directly.
    public func landCommit(_ sha: String, _ files: [NodeFile]) {
        commitScope = sha
        commitFiles = (sha, files)
    }

    private func tabMoved(_ from: String) {
        guard let app, case .review = app.router.route else { return }
        if tab == "files" { app.focus(pane: reviewDiffPane) }
        if tab == "commits" { app.focus(pane: ShipSeam.historyPane) }
    }

    // ── context ──

    var contextKey: String { "\(keyOf)|\(commitScope ?? "")" }

    func contextOf(_ path: String) -> Context? { context.key == contextKey ? context.files[path] : nil }

    private func putContext(_ key: String, _ path: String, _ c: Context) {
        var files = context.key == key ? context.files : [:]
        files[path] = c
        context = (key, files)
    }

    /// Show `n` more hidden lines at a gap; returns once the file's text is here.
    public func reveal(_ path: String, at: Int, n: Int = 20) async {
        let key = contextKey
        let was = contextOf(path) ?? Context(lines: nil, reveal: [:])
        var r = was.reveal
        r[at, default: 0] += n
        putContext(key, path, Context(lines: was.lines, reveal: r))
        guard was.lines == nil, let t = target, let app else { return }
        let rev = commitScope ?? (integration != nil ? t.name : tip)
        guard !rev.isEmpty else { return }
        let text = await app.transport.getText(repoPath("/file?branch=\(rev.uriComponent)&path=\(path.uriComponent)"))
        guard let text, contextKey == key else { return }
        putContext(key, path, Context(lines: text.components(separatedBy: "\n"), reveal: contextOf(path)?.reveal ?? r))
    }

    /// Tests set a file's text without the server.
    func setContextLines(_ path: String, _ lines: [String]) {
        putContext(contextKey, path, Context(lines: lines, reveal: contextOf(path)?.reveal ?? [:]))
    }

    // ── threads, drafts, viewed ──

    @ObservationIgnored private var threadsMemo: (sig: String, review: Int, ops: [Int], threads: [CanopyCore.Thread])?

    public var threads: [CanopyCore.Thread] {
        guard let app, let t = target else { return [] }
        let v = app.store.versions[Domain.review] ?? 0, ops = app.store.ops.map(\.seq)
        if let m = threadsMemo, m.sig == t.id, m.review == v, m.ops == ops { return m.threads }
        let out = app.store.table(CanopyCore.Thread.self).values
            .filter { $0.branch == t.name && $0.repo == t.repo }
            .sorted { $0.id < $1.id }
            .compactMap { app.store.view(CanopyCore.Thread.self, $0.id) }
        threadsMemo = (t.id, v, ops, out)
        return out
    }

    public var items: [DraftItem] { (draft?.items ?? []).filter(isLocal) }

    /// Replies not on GitHub yet, by thread id.
    public func repliesTo(_ threadID: String) -> [DraftItem] { items.filter { $0.kind == "reply" && $0.threadId == threadID } }

    /// The server's marks across this repo's branches: a change read on one branch reads as read wherever
    /// it shows — a child carrying it, the cumulative view (decided 2026-11-05; per branch before then).
    public var serverMarks: (viewed: Set<String>, flagged: Set<String>) {
        guard let app, let repo = target?.repo else { return ([], []) }
        var viewed = Set<String>(), flagged = Set<String>()
        for e in app.store.table(Viewed.self).values where e.repo == repo {
            viewed.formUnion(e.keys)
            flagged.formUnion(e.flagged ?? [])
        }
        return (viewed, flagged)
    }

    public func serverMark(_ key: String) -> Mark {
        let s = serverMarks
        return s.flagged.contains(key) ? .flagged : s.viewed.contains(key) ? .viewed : .unread
    }

    public func mark(_ b: Block) -> Mark { mark(b, serverMarks) }

    func mark(_ b: Block, _ s: (viewed: Set<String>, flagged: Set<String>)) -> Mark {
        if let o = viewedOverride[b.key] { return o }
        if s.flagged.contains(b.key) { return .flagged }
        return s.viewed.contains(b.key) || s.viewed.contains(b.legacy) ? .viewed : .unread
    }

    public func isSeen(_ b: Block) -> Bool { mark(b) == .viewed }

    /// An override the server now agrees with has done its job; dropping it lets later changes through.
    private func storeMoved() {
        guard !viewedOverride.isEmpty else { return }
        let keep = viewedOverride.filter { serverMark($0.key) != $0.value }
        if keep.count != viewedOverride.count { viewedOverride = keep }
    }

    public func isOpen(_ t: CanopyCore.Thread) -> Bool {
        guard let app else { return !t.resolved && !t.outdated }
        return ShipState.of(app).isOpen(t)
    }

    // ── the diff as the page shows it (memoized: a 5k-line diff is read on every key) ──

    @ObservationIgnored private var parsed: (key: String, files: [FileDiff])?
    @ObservationIgnored private var parsedScoped: (sha: String, files: [FileDiff])?
    @ObservationIgnored private var rowCache: [String: [DiffRow]] = [:]
    @ObservationIgnored private var blockCache: [String: [Block]] = [:]
    @ObservationIgnored private var viewsMemo: (sig: ViewsSig, views: [FileView])?
    @ObservationIgnored private var stopsMemo: (sig: StopsSig, stops: [Stop], index: [String: Int], keys: [String])?

    private static func parse(_ fs: [NodeFile]) -> [FileDiff] {
        fs.map { f in var d = parsePatch(f.path, f.patch); d.add = f.add; d.del = f.del; return d }
    }

    /// The whole branch's files, whichever commit the diff is showing — what the header counts.
    public var branchFiles: [FileDiff] {
        guard let p = payload else { return [] }
        if parsed?.key != p.key { parsed = (p.key, Self.parse(p.data.files)) }
        return parsed!.files
    }

    public var files: [FileDiff] {
        guard let sha = commitScope else { return branchFiles }
        guard let cf = commitFiles, cf.sha == sha else { return [] }
        if parsedScoped?.sha != sha { parsedScoped = (sha, Self.parse(cf.files)) }
        return parsedScoped!.files
    }

    func rowsOf(_ f: FileDiff, _ split: Bool, _ salt: String) -> [DiffRow] {
        let k = "\(salt)|\(split)|\(f.path)"
        if let r = rowCache[k] { return r }
        let r = split ? splitRows(f) : unifiedRows(f)
        if rowCache.count > 2000 { rowCache = [:] }
        rowCache[k] = r
        return r
    }

    func blocksOfCached(_ f: FileDiff, _ salt: String) -> [Block] {
        let k = "\(salt)|\(f.path)"
        if let b = blockCache[k] { return b }
        let b = blocksOf(f)
        if blockCache.count > 2000 { blockCache = [:] }
        blockCache[k] = b
        return b
    }

    struct ViewsSig: Equatable {
        var payload: String
        var scope: String?
        var scopeLoaded: Bool
        var split: Bool
        /// Threads, drafts, viewed marks and convs patch under `review`; a git patch (any branch's tip) leaves the diff as it was.
        var review: Int
        var ops: [Int]
        var context: Int
        var override: [String: Mark]
        var showOutdated: Bool
    }

    private var viewsSig: ViewsSig {
        ViewsSig(payload: "\(payloadGen)|\(payload?.key ?? "")", scope: commitScope, scopeLoaded: commitFiles?.sha == commitScope, split: split,
                 review: app?.store.versions[Domain.review] ?? 0, ops: app?.store.ops.map(\.seq) ?? [], context: contextGen,
                 override: viewedOverride, showOutdated: showOutdated)
    }

    public var views: [FileView] {
        let sig = viewsSig
        if let m = viewsMemo, m.sig == sig { return m.views }
        let v = buildViews()
        viewsMemo = (sig, v)
        return v
    }

    private func buildViews() -> [FileView] {
        let sp = split
        let salt = commitScope.map { "c:\($0)" } ?? (payload?.key ?? "")
        let fs = files
        if scoped {
            // one commit, read-only: its lines are that commit's, so no threads, drafts or viewed marks
            return fs.map { raw in
                let c = contextOf(raw.path)
                let (file, gaps) = expand(raw, c?.lines, c?.reveal ?? [:])
                let rows = c == nil ? rowsOf(file, sp, salt) : (sp ? splitRows(file) : unifiedRows(file))
                return FileView(file: file, rows: rows, threadsAt: [:], pendingAt: [:], aside: [], open: 0, viewed: false,
                                blocks: [], seen: 0, gaps: gaps)
            }
        }
        var byPath: [String: [CanopyCore.Thread]] = [:]
        for t in threads { byPath[t.path, default: []].append(t) }
        var pend: [String: [DraftItem]] = [:]
        for c in items where c.kind == "comment" { if let p = c.path { pend[p, default: []].append(c) } }
        let server = serverMarks
        return fs.map { raw in
            let c = contextOf(raw.path)
            let (file, gaps) = expand(raw, c?.lines, c?.reveal ?? [:])
            let rows = c?.lines == nil ? rowsOf(file, sp, salt) : (sp ? splitRows(file) : unifiedRows(file))
            var anchors = Set<String>()
            for r in rows { for a in rowAnchors(r) { anchors.insert(a) } }
            var threadsAt: [String: [CanopyCore.Thread]] = [:]
            var aside: [CanopyCore.Thread] = []
            for t in byPath[file.path] ?? [] {
                let a = t.local.map { "\(t.side == .left ? "L" : "R"):\($0.line)" } ?? ""
                if !a.isEmpty && anchors.contains(a) { threadsAt[a, default: []].append(t) } else { aside.append(t) }
            }
            var pendingAt: [String: [DraftItem]] = [:]
            for c in pend[file.path] ?? [] { pendingAt["\(c.side == .left ? "L" : "R"):\(c.line ?? 0)", default: []].append(c) }
            let open = (byPath[file.path] ?? []).filter { !$0.resolved && !$0.outdated }.count
            let blocks = blocksOfCached(raw, salt)
            let marks = blocks.map { mark($0, server) }
            let lineBlock = blockAnchors(raw)
            var rowBlock: [String: Int] = [:]
            for r in rows {
                guard let l = [r.left, r.right].compactMap({ $0 }).first(where: { $0.kind != .ctx }), let b = lineBlock[anchorOf(l)] else { continue }
                rowBlock[r.key] = b
            }
            let seen = marks.filter { $0 == .viewed }.count
            return FileView(file: file, rows: rows, threadsAt: threadsAt, pendingAt: pendingAt, aside: aside, open: open,
                            viewed: !blocks.isEmpty && seen == blocks.count, blocks: blocks, seen: seen,
                            flagged: marks.filter { $0 == .flagged }.count, rowBlock: rowBlock, marks: marks, gaps: gaps)
        }
    }

    /// Files of the whole branch with every change viewed — the header's count.
    public var branchViewed: Int {
        branchFiles.filter { f in
            let bs = blocksOfCached(f, payload?.key ?? "")
            return !bs.isEmpty && bs.allSatisfy(isSeen)
        }.count
    }

    /// Threads not on any file of this diff (a file the branch no longer changes).
    public var elsewhere: [CanopyCore.Thread] {
        if scoped { return [] }
        let paths = Set(files.map(\.path))
        return threads.filter { !paths.contains($0.path) && (!$0.outdated || showOutdated) }
    }

    public func fileOf(_ path: String) -> FileView? { views.first { $0.file.path == path } }

    /// Where the change with block key `key` is: its file, its first changed line and that line's text.
    public func flagPlace(_ key: String) -> (path: String, line: Int, text: String)? {
        for fv in views {
            guard let b = fv.blocks.firstIndex(where: { $0.key == key }) else { continue }
            let row = fv.rows.first { fv.rowBlock[$0.key] == b }
            let l = row?.right ?? row?.left
            return (fv.file.path, l?.new ?? l?.old ?? 0, l?.text ?? "")
        }
        return nil
    }

    /// The first changed row of the change with block key `key` in `path`, as a stop key.
    public func stopOf(block key: String, in path: String) -> String? {
        guard let fv = fileOf(path), let b = fv.blocks.firstIndex(where: { $0.key == key }),
              let row = fv.rows.first(where: { fv.rowBlock[$0.key] == b }) else { return nil }
        return "l|\(path)|\(row.key)"
    }

    /// Put the cursor on a flagged change: on its block when the diff still has it, else the nearest
    /// line to where it was; on a page still loading, once its diff is here.
    public func land(flag f: Flag) {
        if diffHere, let k = stopOf(block: f.key, in: f.path) ?? stopNear(path: f.path, line: f.line) {
            pendingFlag = nil
            return setCursor(k)
        }
        pendingFlag = (id, f)
    }

    /// The mark on the change a stop sits on; nil off a changed line.
    public func markAt(_ k: Int) -> Mark? {
        guard stops.indices.contains(k), let row = stops[k].row, let fv = fileOf(stops[k].path) else { return nil }
        return fv.mark(of: row)
    }

    struct StopsSig: Equatable {
        var views: ViewsSig
        var outdated: Bool
        var open: [String]
    }

    /// The diff's cursor stops, top to bottom: each file's header, then (unless it's viewed) its
    /// aside threads, its gaps and rows with what hangs under each.
    public var stops: [Stop] { stopsMemoized.stops }
    public var stopIndex: [String: Int] { stopsMemoized.index }
    /// The stops' keys — the diff pane's rows.
    public var stopKeys: [String] { stopsMemoized.keys }

    private var stopsMemoized: (stops: [Stop], index: [String: Int], keys: [String]) {
        let vs = views
        let open = threads.filter { isOpen($0) }.map(\.id)
        let sig = StopsSig(views: viewsSig, outdated: showOutdated, open: open)
        if let m = stopsMemo, m.sig == sig { return (m.stops, m.index, m.keys) }
        let s = buildStops(vs)
        var index: [String: Int] = [:]
        index.reserveCapacity(s.count)
        for (i, st) in s.enumerated() where index[st.key] == nil { index[st.key] = i }
        let keys = s.map(\.key)
        stopsMemo = (sig, s, index, keys)
        return (s, index, keys)
    }

    private func buildStops(_ vs: [FileView]) -> [Stop] {
        var out: [Stop] = []
        let replies = Dictionary(grouping: items.filter { $0.kind == "reply" }) { $0.threadId ?? "" }
        for fv in vs {
            let path = fv.file.path
            out.append(Stop(key: "f|\(path)", kind: .file, path: path))
            if fv.viewed { continue }
            func thread(_ t: CanopyCore.Thread) {
                out.append(Stop(key: "t|\(t.id)", kind: .thread, path: path, id: t.id))
                if isOpen(t) { for r in replies[t.id] ?? [] { out.append(Stop(key: "p|\(r.key)", kind: .pending, path: path, id: r.key)) } }
            }
            for t in fv.aside where !t.outdated || showOutdated { thread(t) }
            let gapAt = Set(fv.gaps.map(\.at))
            func gap(_ at: Int) { if gapAt.contains(at) { out.append(Stop(key: "g|\(path)|\(at)", kind: .gap, path: path, at: at)) } }
            for (i, r) in fv.rows.enumerated() {
                if i == 0 || fv.rows[i - 1].hunk != r.hunk { gap(r.hunk) }
                out.append(Stop(key: "l|\(path)|\(r.key)", kind: .line, path: path, row: r))
                let at = fv.at(r)
                for t in at.threads { thread(t) }
                for c in at.pending { out.append(Stop(key: "p|\(c.key)", kind: .pending, path: path, id: c.key)) }
            }
            gap(fv.file.hunks.count)
        }
        for t in elsewhere {
            out.append(Stop(key: "t|\(t.id)", kind: .thread, path: t.path, id: t.id))
        }
        return out
    }

    // ── the cursor ──

    var diffPaneKey: String { "review/\(reviewDiffPane)" }

    /// The diff pane's cursor key (the shell keeps it), whichever pane has focus.
    public var diffCursor: String? { app?.cursors[diffPaneKey] }

    /// The stop under the cursor: the cursor's own while it exists, else whatever now sits in its
    /// place, else the first line (page.ts here).
    public var here: Stop? {
        let s = stops
        guard !s.isEmpty else { return nil }
        if let k = diffCursor {
            if let i = stopIndex[k] { return s[i] }
            let i = app?.cursorIdxs[diffPaneKey] ?? 0
            return s[max(0, min(s.count - 1, i))]
        }
        return stopFiles.first.flatMap(landing(file:)).flatMap { stopIndex[$0] }.map { s[$0] } ?? s.first
    }

    /// Keep the diff cursor `row` lines below the canvas's visible top when it next scrolls to it.
    func anchor(row: Int) {
        if let k = diffCursor { diffCanvas.canvas.anchor = (k, row) }
    }

    private func takePendingRow() {
        guard let r = pendingRow, r.id == id else { return }
        pendingRow = nil
        if diffWindow != nil { anchor(row: r.row) }
    }

    /// A click on a line's code: the cursor on that row, on the half clicked where that half is its
    /// own (a removed line), on the character clicked — where h / l would have put it.
    public func click(_ key: String, side: Side, at: Int) {
        guard let i = stopIndex[key], let row = stops[i].row else { return }
        let s: Side = row.right?.new == nil ? .left : side == .left && row.left?.kind == .del ? .left : .right
        guard let t = (s == .left ? row.left : row.right)?.text as NSString?, t.length > 0 else { return }
        let r = t.rangeOfComposedCharacterSequence(at: min(max(0, at), t.length - 1))
        column = s
        word = (key, s, r.location..<(r.location + r.length))
        cursorMoved &+= 1
    }

    /// Where every jump into a file lands: its first changed line, else its first line, else its
    /// header (a viewed file folds to just that). Jumps land on code you can act on.
    public func landing(file path: String) -> String? {
        let s = stops
        guard let h = stopIndex["f|\(path)"] else { return nil }
        var firstLine: String?
        var i = h + 1
        while i < s.count, s[i].kind != .file, s[i].path == path {
            if let row = s[i].row {
                if changed(row) { return s[i].key }
                firstLine = firstLine ?? s[i].key
            }
            i += 1
        }
        return firstLine ?? s[h].key
    }
    /// Where each change starts, as stop indexes: a changed line whose line before (conversations
    /// under it don't count) is unchanged, in another hunk or file, or across hidden lines. A change
    /// is finer than git's hunk, which can hold two edits — `]` and the statusline both count these.
    public var changeStarts: [Int] {
        var out: [Int] = []
        var prev: Stop?
        for (k, st) in stops.enumerated() {
            switch st.kind {
            case .line:
                if let row = st.row, changed(row) {
                    let joins = prev.flatMap { p in p.row.map { changed($0) && p.path == st.path && $0.hunk == row.hunk } } ?? false
                    if !joins { out.append(k) }
                }
                prev = st
            case .thread, .pending: continue
            case .file, .gap: prev = nil
            }
        }
        return out
    }
    /// The files in the diff's order.
    public var stopFiles: [String] { stops.filter { $0.kind == .file }.map(\.path) }

    /// Put the cursor on a file's first change, its header at the top of the diff.
    @discardableResult
    public func goTo(file path: String) -> Bool {
        guard let k = landing(file: path) else { return false }
        diffCanvas.canvas.lead = (k, "f|\(path)")
        setCursor(k)
        return true
    }

    /// Put the diff cursor on a stop. `focus`: a jump into the diff — the window shows the diff again
    /// and the keyboard goes there; without it, a window showing a file keeps it and the diff's cursor
    /// waits underneath.
    public func setCursor(_ key: String?, focus: Bool = true) {
        guard let app else { return }
        if focus { showDiff(in: jumpWindow) }
        if diffWindow == nil {
            app.setCursor(key, pane: reviewDiffPane)
            cursorMoved &+= 1
            return
        }
        let was = app.pane?.id
        app.focus(pane: reviewDiffPane)
        app.setCursor(key)
        if !focus, let was, was != reviewDiffPane { app.focus(pane: was) }
        cursorMoved &+= 1
    }

    /// The word under the pointer over the diff, and the cursor move it came after: the pointer
    /// counts for K / g d only while nothing has moved the cursor since (whichever was used last wins).
    @ObservationIgnored public var pointer: (pos: CodeLookup.Position, seq: Int, key: String?)?

    /// Bumped on every cursor move made here (the canvas scrolls to it; the pointer yields to it).
    public var cursorMoved = 0

    /// The commentable line range under the cursor (and the mark `x` dropped).
    public var range: ReviewLineRange? {
        guard let h = here, h.kind == .line, let row = h.row else { return nil }
        let end = sideLine(row, prefer: column)
        let m = mark.flatMap { stopIndex[$0] }.map { stops[$0] }
        guard let m, m.kind == .line, m.path == h.path, let mrow = m.row else { return ReviewLineRange(path: h.path, side: end.side, line: end.line) }
        let start = sideLine(mrow, prefer: column)
        if start.side != end.side { return ReviewLineRange(path: h.path, side: end.side, line: end.line) }
        let (a, b) = start.line <= end.line ? (start.line, end.line) : (end.line, start.line)
        return ReviewLineRange(path: h.path, side: end.side, line: b, startLine: a == b ? nil : a)
    }

    /// The new side's lines `from…to` as the diff shows them — what a suggestion replaces.
    public func newLines(path: String, from: Int, to: Int) -> [String] {
        (fileOf(path)?.rows ?? []).compactMap { r in
            guard let l = r.right, let n = l.new, l.kind != .del, n >= from, n <= to else { return nil }
            return l.text
        }
    }

    /// Put the cursor on a thread at its line (ShipHost.showThread).
    public func showThread(_ threadID: String) {
        guard let t = app?.store.view(CanopyCore.Thread.self, threadID) else { return }
        tab = "files"
        if t.outdated { showOutdated = true }
        if let app { ShipState.of(app).unfold[t.id] = true }
        setCursor("t|\(t.id)")
    }

    // ── side.ts ──

    /// Open a place in the window: the diff when it's a line of it, else the file at its commit, in the diff's place.
    public func open(_ l: Loc) {
        if l.sha.isEmpty, l.repo == target?.repo {
            // an address's line: on the tip, which only the diff can place
            guard diffHere, !tip.isEmpty else { pendingLoc = (id, l); return }
            var at = l
            at.sha = tip
            return open(at)
        }
        if let k = l.diffKey, stopIndex[k] == nil, l.repo == target?.repo {
            // the diff isn't here yet (a jumplist entry on another branch): land there once it is
            pendingCursor = (id, k)
            return
        }
        if !l.asFile, let key = inDiff(l) {
            diffCanvas.canvas.middle = key
            setCursor(key)
            return
        }
        show(l)
    }

    func inDiff(_ l: Loc) -> String? {
        if let k = l.diffKey, stopIndex[k] != nil { return k }
        guard l.sha == tip, !tip.isEmpty else { return nil }
        return stops.first { $0.kind == .line && $0.path == l.path && $0.row?.right?.new == l.line }?.key
    }

    func show(_ l: Loc) { show(l, in: jumpWindow) }

    /// A file at a commit, as lines (GET /lsp/src → {text}); cached.
    public func linesOf(_ l: Loc) async -> [String] {
        let k = "\(l.repo)|\(l.sha)|\(l.path)"
        if let c = srcCache[k] { return c }
        guard let app else { return [] }
        let path = app.transport.atRepo(l.repo, "/lsp/src?path=\(l.path.uriComponent)&sha=\(l.sha.uriComponent)")
        let text = await app.transport.getText(path)
        let src = text.flatMap { try? JSONDecoder().decode(LSPSource.self, from: Data($0.utf8)) }
        let lines = (src?.text ?? "").components(separatedBy: "\n")
        srcCache[k] = lines
        return lines
    }

    /// Where code navigation is now: the focused window's line (the file's, or the diff cursor's);
    /// outside the windows, the first window's.
    public func herePlace() -> Loc? {
        let w = focusedWindow ?? windows[0]
        if let s = w.doc {
            let line = (w === focusedWindow ? RowKey.id(app?.selected, "s").flatMap(Int.init) : nil) ?? s.line
            return Loc(repo: s.repo, sha: s.sha, path: s.path, line: line, asFile: true)
        }
        guard let h = here, h.kind == .line, let row = h.row, let t = target else { return nil }
        return Loc(repo: t.repo, sha: tip, path: h.path, line: row.right?.new ?? row.left?.old ?? 1, diffKey: h.key)
    }

    /// The focused file's rows.
    var sideRows: [String] { (code ?? windows.first { $0.doc != nil })?.codeRows ?? [] }
}

// ── ShipHost: what the review page tells Ship (area C) ──

public extension ReviewPageState {
    func lineRange(_ app: AppModel) -> ShipLineRange? {
        range.map { ShipLineRange(path: $0.path, side: $0.side, line: $0.line, startLine: $0.startLine) }
    }
    func newLines(_ app: AppModel, path: String, from: Int, to: Int) -> [String] { newLines(path: path, from: from, to: to) }
    func showThread(_ app: AppModel, id: String) { showThread(id) }
    /// history.enter / commit.back: focus moves between the history list and the commit's diff.
    func focusDiff(_ app: AppModel, _ on: Bool) { app.focus(pane: on ? reviewDiffPane : ShipSeam.historyPane) }
    func clearMark() { mark = nil }

    func beginEdit(_ app: AppModel) -> Bool {
        guard helix == nil, app.pane?.id == reviewDiffPane, !scoped, integration == nil, let t = target,
              let h = here, h.kind == .line, let row = h.row else { return false }
        let at = sideLine(row, prefer: column)
        guard at.side == .right else { return false }
        openHelix(app, branch: t.name, path: h.path, line: at.line, col: (hereWord?.lowerBound ?? 0) + 1)
        return true
    }

    /// `o`: Helix over the whole page, on the file and line under the cursor.
    func openHelixWhole(_ app: AppModel) -> Bool {
        guard helix == nil, integration == nil, let t = target else { return false }
        if let s = code?.doc {
            let line = RowKey.id(app.selected, "s").flatMap(Int.init) ?? s.line
            openHelix(app, branch: t.name, path: s.path, line: line, col: (sideHereWord?.lowerBound ?? 0) + 1, whole: true, fromSide: true)
            return true
        }
        guard let h = here else { return false }
        var line = tipLineNear(h) ?? 1, col = 1
        if h.kind == .line, let row = h.row, sideLine(row, prefer: column).side == .right, let w = hereWord { col = w.lowerBound + 1 }
        if h.kind == .thread, let l = h.id.flatMap({ app.store.view(CanopyCore.Thread.self, $0) })?.local?.line { line = l }
        openHelix(app, branch: t.name, path: h.path, line: line, col: col, whole: true)
        return true
    }

    /// The tip's line at a stop: its new half, else (a removed line, a gap, the file's header) the nearest new
    /// line after it in its file, else before. A removed line's own number belongs to the old file, not the tip.
    func tipLineNear(_ s: Stop) -> Int? {
        if let n = s.row?.right?.new { return n }
        guard let i = stopIndex[s.key] else { return nil }
        let all = stops
        let ahead = all[i...].prefix { $0.path == s.path }.lazy.compactMap { $0.row?.right?.new }.first
        return ahead ?? all[..<i].reversed().prefix { $0.path == s.path }.lazy.compactMap { $0.row?.right?.new }.first
    }

    /// The diff's stop nearest a tip line of a file: that line, else the closest line the diff shows, else the file.
    func stopNear(path: String, line: Int) -> String? {
        let inFile = stops.filter { $0.path == path }
        let lines = inFile.compactMap { s in s.kind == .line ? s.row?.right?.new.map { (s.key, $0) } : nil }
        return lines.min { abs($0.1 - line) < abs($1.1 - line) }?.0 ?? inFile.first?.key
    }
}
