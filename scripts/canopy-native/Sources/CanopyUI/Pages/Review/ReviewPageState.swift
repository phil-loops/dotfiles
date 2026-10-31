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
    /// how many of its blocks are viewed, and the hunks whose blocks all are
    public var seen: Int
    public var seenHunks: Set<Int>
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

/// The side and line number a row is commented on: its new line when it has one.
public func sideLine(_ r: DiffRow) -> (side: Side, line: Int) {
    if let n = r.right?.new { return (.right, n) }
    return (.left, r.left?.old ?? 0)
}

public let reviewDiffPane = "diff"
public let reviewTreePane = "files"
public let reviewCodePane = "code"

@MainActor
@Observable
public final class ReviewPageState: ShipHost {
    @ObservationIgnored weak var app: AppModel?

    /// The diff's canvas and the side pane's, kept here so commands and the label layer can reach them.
    @ObservationIgnored let diffCanvas = CanvasHandle()
    @ObservationIgnored let sideCanvas = CanvasHandle()

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
    public var showOutdated = false
    /// where `x` dropped its mark (the other end of a range comment)
    public var mark: String?
    /// block key → viewed, ahead of the server's copy while a write is in flight
    public var viewedOverride: [String: Bool] = [:]
    /// the file tree's filter (space f), and the page search (/)
    public var filter = ""
    public var search = ""
    /// the forest map overlay is up (space m) — its layer's cursor
    public var mapIndex = 0
    /// the commit whose diff the commits tab shows (Ship's commitScope, mirrored), and its files
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
    /// The branch the page last showed (a new one starts fresh).
    @ObservationIgnored private var shownID = ""

    // ── side.ts: a place outside the diff, open beside it ──

    public private(set) var side: Loc?
    public private(set) var sideText: String?
    @ObservationIgnored private var srcCache: [String: [String]] = [:]

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

    func repoPath(_ p: String) -> String { app?.transport.atRepo(target?.repo ?? "", p) ?? p }

    // ── loading ──

    /// Bring the page up to its address: a new branch starts fresh, a new tip or base reads its diff
    /// (the old one stays up until the new one lands). Views call it on appear and on change.
    public func sync() {
        guard let t = target else { return }
        if shownID != t.id {
            let first = shownID.isEmpty
            shownID = t.id
            if !first || payload != nil { resetForNewBranch(t.id) }
        }
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

    /// Take a diff as read (tests hand one in directly).
    public func land(_ key: String, _ data: NodePayload) {
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
        side = nil
        sideText = nil
        if let c = carry, c.id == newID { tab = c.tab } else { carry = nil; tab = "files" }
        guard let app else { return }
        // a jumplist entry being restored already put its cursor
        if pendingCursor?.id == newID { return }
        let was = app.pane?.id
        app.focus(pane: reviewDiffPane)
        app.setCursor(nil)
        if let was, was == reviewTreePane { app.focus(pane: was) }
    }

    /// Once a diff is here: put the cursor where a J/K hop or a jumplist entry wants it, or on the
    /// first line (page.ts here()'s default) when it has none.
    private func settleCursor() {
        let s = stops
        if let c = carry, c.id == id {
            carry = nil
            if let p = c.path, stopIndex["f|\(p)"] != nil { return setCursor("f|\(p)", focus: false) }
            if let first = s.first(where: { $0.kind == .line }) ?? s.first { return setCursor(first.key, focus: false) }
            return
        }
        if let p = pendingCursor, p.id == id, stopIndex[p.key] != nil {
            pendingCursor = nil
            return setCursor(p.key, focus: false)
        }
        // a page opening for the first time puts the keyboard in the diff
        let fresh = app?.focusedPane["review"] == nil
        if diffCursor == nil, let first = s.first(where: { $0.kind == .line }) ?? s.first { setCursor(first.key, focus: fresh) }
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

    // ── one commit's diff (the commits tab) ──

    /// ShipHost.commitScopeChanged: show one commit's diff (GET /commit-diff), or the branch again.
    public func commitScopeChanged(_ sha: String?) {
        commitScope = sha
        mark = nil
        if let first = stops.first(where: { $0.kind == .line }) { setCursor(first.key, focus: false) }
        guard let sha, commitFiles?.sha != sha, let app else { return }
        let path = repoPath("/commit-diff?sha=\(sha.uriComponent)")
        Task { @MainActor [weak self] in
            struct CommitDiff: Decodable { var sha: String?; var files: [NodeFile] }
            guard let got = try? await app.transport.getJSON(path, as: CommitDiff.self), let self, self.commitScope == sha else { return }
            self.commitFiles = (sha, got.files)
            if let first = self.stops.first(where: { $0.kind == .line }) { self.setCursor(first.key, focus: false) }
        }
    }

    /// Tests and the inline view hand a commit's files in directly.
    public func landCommit(_ sha: String, _ files: [NodeFile]) {
        commitScope = sha
        commitFiles = (sha, files)
    }

    private func tabMoved(_ from: String) {
        if tab != "commits" && commitScope != nil { commitScope = nil }
        guard let app, case .review = app.router.route else { return }
        if tab == "files" { app.focus(pane: reviewDiffPane) }
        if tab == "commits" {
            app.focus(pane: ShipSeam.historyPane)
            app.setCursor("h|\(commitScope ?? "")")
        }
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

    @ObservationIgnored private var threadsMemo: (sig: String, versions: Versions, ops: [Int], threads: [CanopyCore.Thread])?

    public var threads: [CanopyCore.Thread] {
        guard let app, let t = target else { return [] }
        let v = app.store.versions, ops = app.store.ops.map(\.seq)
        if let m = threadsMemo, m.sig == t.id, m.versions == v, m.ops == ops { return m.threads }
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

    public var serverViewed: Set<String> { Set(app?.store.view(Viewed.self, id)?.keys ?? []) }

    public func isSeen(_ key: String) -> Bool { viewedOverride[key] ?? serverViewed.contains(key) }

    /// An override the server now agrees with has done its job; dropping it lets later changes through.
    private func storeMoved() {
        guard !viewedOverride.isEmpty else { return }
        let srv = serverViewed
        let keep = viewedOverride.filter { srv.contains($0.key) != $0.value }
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
        var versions: Versions
        var ops: [Int]
        var context: Int
        var override: [String: Bool]
        var showOutdated: Bool
    }

    private var viewsSig: ViewsSig {
        ViewsSig(payload: "\(payloadGen)|\(payload?.key ?? "")", scope: commitScope, scopeLoaded: commitFiles?.sha == commitScope, split: split,
                 versions: app?.store.versions ?? [:], ops: app?.store.ops.map(\.seq) ?? [], context: contextGen,
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
                                blocks: [], seen: 0, seenHunks: [], gaps: gaps)
            }
        }
        var byPath: [String: [CanopyCore.Thread]] = [:]
        for t in threads { byPath[t.path, default: []].append(t) }
        var pend: [String: [DraftItem]] = [:]
        for c in items where c.kind == "comment" { if let p = c.path { pend[p, default: []].append(c) } }
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
            let seenKeys = blocks.filter { isSeen($0.key) }
            var seenHunks = Set<Int>()
            for i in raw.hunks.indices where blocks.contains(where: { $0.hunk == i }) && blocks.allSatisfy({ $0.hunk != i || isSeen($0.key) }) {
                seenHunks.insert(i)
            }
            let viewed = !blocks.isEmpty && seenKeys.count == blocks.count
            return FileView(file: file, rows: rows, threadsAt: threadsAt, pendingAt: pendingAt, aside: aside, open: open, viewed: viewed,
                            blocks: blocks, seen: seenKeys.count, seenHunks: seenHunks, gaps: gaps)
        }
    }

    /// Files of the whole branch with every change viewed — the header's count.
    public var branchViewed: Int {
        branchFiles.filter { f in
            let bs = blocksOfCached(f, payload?.key ?? "")
            return !bs.isEmpty && bs.allSatisfy { isSeen($0.key) }
        }.count
    }

    /// Threads not on any file of this diff (a file the branch no longer changes).
    public var elsewhere: [CanopyCore.Thread] {
        if scoped { return [] }
        let paths = Set(files.map(\.path))
        return threads.filter { !paths.contains($0.path) && (!$0.outdated || showOutdated) }
    }

    public func fileOf(_ path: String) -> FileView? { views.first { $0.file.path == path } }

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
        return s.first { $0.kind == .line } ?? s.first
    }

    /// Put the diff cursor on a stop; `focus` moves the keyboard to the diff too.
    public func setCursor(_ key: String?, focus: Bool = true) {
        guard let app else { return }
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
        let end = sideLine(row)
        let m = mark.flatMap { stopIndex[$0] }.map { stops[$0] }
        guard let m, m.kind == .line, m.path == h.path, let mrow = m.row else { return ReviewLineRange(path: h.path, side: end.side, line: end.line) }
        let start = sideLine(mrow)
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

    /// Open a place: in the diff when it's a line of it, else beside the diff at its commit.
    public func open(_ l: Loc) {
        if let k = l.diffKey, stopIndex[k] == nil, l.repo == target?.repo {
            // the diff isn't here yet (a jumplist entry on another branch): land there once it is
            pendingCursor = (id, k)
            return
        }
        if let key = inDiff(l) {
            side = nil
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

    func show(_ l: Loc) {
        let same = side
        side = l
        guard let app else { return }
        app.focus(pane: reviewCodePane)
        app.setCursor("s:\(l.line)")
        if let same, same.repo == l.repo, same.sha == l.sha, same.path == l.path { return }
        sideText = nil
        let k = "\(l.repo)|\(l.sha)|\(l.path)"
        if let lines = srcCache[k] { sideText = lines.joined(separator: "\n"); app.setCursor("s:\(l.line)"); return }
        Task { @MainActor [weak self] in
            let lines = await self?.linesOf(l) ?? []
            guard let self, self.side == l else { return }
            self.sideText = lines.joined(separator: "\n")
            if self.app?.pane?.id == reviewCodePane { self.app?.setCursor("s:\(l.line)") }
        }
    }

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

    /// Where code navigation is now: the side pane's line while it's open and focused, else the
    /// diff cursor's line.
    public func herePlace() -> Loc? {
        if let s = side, app?.pane?.id == reviewCodePane {
            let line = RowKey.id(app?.selected, "s").flatMap(Int.init) ?? s.line
            return Loc(repo: s.repo, sha: s.sha, path: s.path, line: line)
        }
        if let s = side { return s }
        guard let h = here, h.kind == .line, let row = h.row, let t = target else { return nil }
        return Loc(repo: t.repo, sha: tip, path: h.path, line: row.right?.new ?? row.left?.old ?? 1, diffKey: h.key)
    }

    public func closeSide() {
        guard side != nil else { return }
        side = nil
        sideText = nil
        app?.focus(pane: reviewDiffPane)
    }

    /// The side pane's rows: one per line of the file ("s:<n>").
    var sideRows: [String] {
        guard side != nil, let t = sideText else { return [] }
        return (1...max(1, t.components(separatedBy: "\n").count)).map { "s:\($0)" }
    }
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
}
