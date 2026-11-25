import CanopyCore
import Foundation
import Observation

/// One branch as the pages show it: the entity, its PR, where it stands, its compare base.
public struct BranchView: Equatable {
    public var b: Branch
    public var pr: Pr?
    public var st: Stand
    /// the compare form's base: the parent while it's unlanded, else trunk
    public var base: String
    /// the chats on it — bound to it or acting on it (rounds 27–28); the situation's agent reads the same list
    var chats: [WorkContext.Chat] = []

    /// Whether someone other than Phil is on it: an agent holds its move, or finished a turn and handed it back.
    public var worked: Bool {
        if case .agent = st.actor { return true }
        return st.awaiting != nil
    }
}

/// One forest as the pages show it.
public struct ForestView: Equatable {
    public var p: Project
    /// in merge order
    public var branches: [BranchView]
    public var ready: [BranchView]
    /// branches with no PR yet — what a launch pushes and opens
    public var unopened: [BranchView]
    public var onGitHub: Int
    public var closed: Bool
    /// where it sits on the home, and its one line: the fold of its branches' situations
    public var move: Move = .waiting
    public var says: String = ""
}

/// An open PR GitHub says awaits my review (GET /review-requests); `imported` once its head is a
/// local review/pr-<N> branch, so ↵ opens it without a fetch.
public struct ReviewRequest: Decodable, Equatable {
    public var number: Int
    public var title: String
    public var author: String
    public var url: String
    public var imported: Bool
}

/// One of my open PRs as GitHub lists it (GET /my-prs, the server's open-PR listing filtered to me): what the home
/// shows for a PR no forest carries — LGTM's "My Pull Requests".
public struct MyPR: Decodable, Equatable {
    public var number: Int
    public var title: String
    public var url: String
    public var draft: Bool
    public var head: String
    public var local: Bool
    public var approvals: Int?
    public var changesRequested: Bool?
    public var mergeState: String?
}

/// What GitHub says about one of my open PRs beyond its state (GET /pr-signals): its row's icons on the home.
public struct PRSignals: Decodable, Equatable {
    public struct Checks: Decodable, Equatable {
        public var pass: Int
        public var fail: Int
        public var running: Int
        public var queued: Int
    }
    public var checks: Checks
    /// unresolved review threads
    public var threads: Int
    /// top-level conversation comments
    public var comments: Int
    public var approvals: Int
    public var changesRequested: Bool
    public var conflicts: Bool
    public struct Strand: Decodable, Equatable {
        public var branch: String
        public var commits: Int
    }
    /// branches above this PR in a native GitHub stack that hold unpushed commits: merging it makes GitHub
    /// rebase them, and those commits are left behind
    public var strands: [Strand]? = nil
}

/// A row of the home's open PRs: one of a forest's branches, or a PR of mine no forest carries.
struct OpenPRRow: Equatable {
    var key: String
    var number: Int
    var title: String
    /// its forest's name, or where it lives when no forest carries it
    var place: String
    var says: String
    var yours: Bool
    var draft: Bool
    var glyph: String
    var branch: BranchView?
    var mine: MyPR?
    var signals: PRSignals?
}

/// One line on the home: a forest, a PR of mine no forest carries, a PR awaiting my review, or a chat owed a reply.
enum HomeItem: Equatable {
    case forest(Project)
    case myPR(MyPR)
    case review(ReviewRequest)
    case reply(WorkContext.Chat, [Project])

    var key: String {
        switch self {
        case .forest(let p): RowKey.project(p.id)
        case .myPR(let p): RowKey.myPR(p.number)
        case .review(let r): RowKey.reviewRequest(r.number)
        case .reply(let c, _): RowKey.reply(c.id)
        }
    }
}

/// What a home group asks of Phil, in the order the home draws them.
enum HomeVerb: CaseIterable {
    case merge, review, reply, step, push, moving, waiting, done

    var isYours: Bool { [.merge, .review, .reply, .step, .push].contains(self) }

    var title: String {
        switch self {
        case .merge: "merge"
        case .review: "review"
        case .reply: "reply"
        case .step: "your move"
        case .push: "push"
        case .moving: "others hold"
        case .waiting: "waiting"
        case .done: "landed"
        }
    }
}

struct HomeSection {
    var verb: HomeVerb
    var items: [HomeItem]
}

/// Whether the whole forest merges onto main (integrate.ts).
public struct IntegrationVerdict: Equatable {
    public enum State: String { case checking, clean, conflicts, failed }
    public var state: State
    public var detail: String
    /// the forest's shape it was asked for: its branches and their tips
    public var stamp: String
}

/// The forests area's state and derived views — model.ts's forest half plus ui.ts's forest bits and
/// integrate.ts. Made once per window (`app.forestModel`); Ship reads `forests`, `branchView`,
/// `armed` and `compareURL` from here. The force scope is Ship's (`ShipState`).
@MainActor
@Observable
public final class ForestModel {
    @ObservationIgnored let store: Store
    @ObservationIgnored let router: Router
    @ObservationIgnored let transport: Transport

    // ── ui.ts ──
    public var showArchive = false
    /// Whether the home also lists what asks nothing of Phil (`yours`); the archive's key shows both.
    public var showParked = false
    /// The branches tmux panes are working on, "repo\tbranch" (PaneBranches): a pane's work is live whatever runs in it.
    public var paneWork: Set<String> = []
    /// the home's chats-on-no-branch line, opened into its list
    public var showLooseChats = false
    /// closed forests shown in the archive fold (display only — their state stays until archived)
    public var shelved: Set<String> = []
    /// forests whose last PR just landed: the "canopy closed" moment before they fold away
    public var closing: Set<String> = []
    public var expanded: Set<String> = []
    public var readyOnly = false
    /// the forest being launched: every node pushed and opened, top to bottom
    public var launching: String?
    /// branches (and landed chapters, by row key) showing their whole commit messages
    public var wordsOpen: Set<String> = []
    /// Each forest page's face: its branches as they stand, or the feature's story. A forest
    /// shows its branches until you flip it; the jumplist keeps the face with the place.
    public var faces: [String: Face] = [:]
    /// The open forest's face.
    public var face: Face {
        get { pageProject.flatMap { faces[$0] } ?? .branches }
        set { if let p = pageProject { faces[p] = newValue } }
    }
    /// the clock stands use to decide whether a hold came due; the pages tick it
    public var now = Date()
    /// The children offered by one `:child` label choice.
    public var childChoice: [String]?

    public private(set) var verdicts: [String: IntegrationVerdict] = [:]
    /// open PRs awaiting my review, newest search first; empty until the first answer
    public private(set) var reviewRequests: [ReviewRequest] = []
    public private(set) var myPRs: [MyPR] = []
    /// my open PRs' row icons by number; empty until the first answer
    public private(set) var prSignals: [Int: PRSignals] = [:]
    @ObservationIgnored var wasClosed: Set<String>?
    /// Archive a forest (the app dispatches `project.archive`, so `u` undoes it).
    @ObservationIgnored var archive: ((String) -> Void)?

    public enum Face: String { case branches, story }

    /// The reads made for a branch's tip beyond the store (ShipState's), and their version for the memo.
    @ObservationIgnored var reads: ((Branch) -> SituationReads)?
    @ObservationIgnored var readsVersion: (() -> Int)?

    @ObservationIgnored let scheduler: Scheduler

    init(store: Store, router: Router, transport: Transport, scheduler: Scheduler = MainScheduler()) {
        self.store = store; self.router = router; self.transport = transport; self.scheduler = scheduler
    }

    // ── model.ts ──

    public func projects() -> (focus: [Project], workbench: [Project], archive: [Project]) {
        let all = store.list(Project.self)
        let byName: (Project, Project) -> Bool = { $0.name != $1.name ? $0.name < $1.name : $0.repo < $1.repo }
        return (
            all.filter { $0.state == .focus && !shelved.contains($0.id) }
                .sorted { ($0.rank ?? 0) != ($1.rank ?? 0) ? ($0.rank ?? 0) < ($1.rank ?? 0) : byName($0, $1) },
            all.filter { $0.state == .workbench && !shelved.contains($0.id) }.sorted(by: byName),
            all.filter { $0.state == .archive || shelved.contains($0.id) }.sorted(by: byName)
        )
    }

    /// Every forest with its branches in merge order, each knowing where it stands. Built once per
    /// store change: the cursor alone asks for it dozens of times a keypress.
    public func forests() -> [String: ForestView] {
        let key = ForestsKey(epoch: store.epoch, store: store.changeCount, now: now, reads: readsVersion?() ?? 0)
        if let memo = forestsMemo, memo.key == key { return memo.value }
        let value = buildForests()
        forestsMemo = (key, value)
        return value
    }

    private struct ForestsKey: Equatable {
        var epoch: String, store: Int, now: Date, reads: Int
    }
    @ObservationIgnored private var forestsMemo: (key: ForestsKey, value: [String: ForestView])?

    private func buildForests() -> [String: ForestView] {
        var groups: [String: [Branch]] = [:]
        for b in store.list(Branch.self) { groups[b.project, default: []].append(b) }
        let prs = store.table(Pr.self)
        let agents = WorkContext.onBranches(store.trackerItems().filter { $0.state == .doing }, store.list(Branch.self))
        let chats = chatsOn(agents)
        var out: [String: ForestView] = [:]
        for p in store.list(Project.self) {
            let bs = (groups[p.id] ?? []).sorted { $0.order != $1.order ? $0.order < $1.order : $0.name < $1.name }
            let trunk = store.repo[p.repo]?.main ?? "main"
            var seen: [String: BranchView] = [:]
            func viewOf(_ b: Branch, _ depth: Int = 0) -> BranchView {
                if let hit = seen[b.id] { return hit }
                let pb = depth < 64 ? b.parentId.flatMap { store.view(Branch.self, $0) } : nil
                let pv = pb.map { viewOf($0, depth + 1) }
                let parent = pv.map { ParentStand(ship: $0.st.ship, pr: $0.pr, name: $0.b.name) }
                let pr = prs[b.id]
                let v = BranchView(b: b, pr: pr, st: ShipRules.stand(b, pr, parent, now: now, reads: readsOf(b, agents[b.id]?.first, chats[b.id] ?? [])), base: ShipRules.baseFor(b, parent, trunk: trunk),
                                   chats: chats[b.id] ?? [])
                seen[b.id] = v
                return v
            }
            let branches = bs.map { viewOf($0) }
            let live = branches.filter { $0.st.ship != .landed }
            out[p.id] = ForestView(p: p, branches: branches, ready: branches.filter(\.st.ready), unopened: live.filter { $0.pr == nil },
                                   onGitHub: branches.filter { $0.pr != nil }.count, closed: ShipRules.isClosed(branches.map { ($0.st.ship, $0.b.role == "proof") }))
            let fold = ShipRules.fold(branches.map { ($0.st, ShipRules.says($0.st, $0.b, $0.pr)) })
            out[p.id]?.move = fold.move
            out[p.id]?.says = fold.says
        }
        return out
    }

    public func forest(_ pid: String?) -> ForestView? { pid.flatMap { forests()[$0] } }

    /// Everything a branch's situation reads beyond the store: the tip's reads, and who is on it — an item's agent, or a
    /// chat bound to it or acting on it while its turn runs (rounds 27–29). An item the journal doesn't observe still names
    /// its agent; an ended turn or an idle chat names nobody — the reply it owes is the home's `replies()`.
    private func readsOf(_ b: Branch, _ item: TodoItem?, _ chats: [WorkContext.Chat]) -> SituationReads {
        var r = reads?(b) ?? SituationReads()
        let worker = item?.work?.worker?.state
        let live = chats.filter { WorkContext.live($0, now: now.timeIntervalSince1970) }
        // a chat holds the branch only while its turn runs; once idle its reply is owed once, on the home's reply line
        // (round 29), and the branch's own route decides where the forest sits
        if worker == "running" || !live.isEmpty {
            r.agent = item?.id ?? live.first.map { "chat \($0.id.prefix(8))" }
            r.agentRunning = true
        } else if let item, worker != "ended" {
            r.agent = item.id
        }
        return r
    }

    /// The chats on each branch, by their binding or their own recent action there (WorkContext.chatsOnBranches).
    private func chatsOn(_ placed: [String: [TodoItem]]) -> [String: [WorkContext.Chat]] {
        let chats = store.rawAll("chat").values.compactMap { try? JSONValue.object($0).decode(WorkContext.Chat.self) }
        guard !chats.isEmpty else { return [:] }
        let branches = store.list(Branch.self)
        var work: [String: String] = [:]
        for b in branches { if let w = store.rawView("branch", b.id)?["work"]?.string { work[b.id] = w } }
        return WorkContext.chatsOnBranches(chats, branches: branches.map(\.id), branchWork: work, placed: placed)
    }

    /// The standing of a branch's parent, as its derivation reads it.
    public func parentStand(of b: Branch) -> ParentStand? {
        branchView(b.parentId).map { ParentStand(ship: $0.st.ship, pr: $0.pr, name: $0.b.name) }
    }

    public func branchView(_ id: String?) -> BranchView? {
        guard let id, let b = store.view(Branch.self, id) else { return nil }
        return forest(b.project)?.branches.first { $0.b.id == id }
    }

    /// A forest's merged PRs, oldest first — its story's opening chapters.
    public func landedOf(_ pid: String) -> [Landed] {
        store.list(Landed.self).filter { $0.project == pid }.sorted { $0.at < $1.at }
    }

    /// The forest a /v2/p/<repo>/<project> page shows, when it exists.
    public var pageProject: String? {
        guard let id = router.route.projectID, store.view(Project.self, id) != nil else { return nil }
        return id
    }

    /// The story's chapters in order: landed, then in flight, then what's left (Story draws the same).
    public func story(_ pid: String) -> (landed: [Landed], inFlight: [BranchView], left: [BranchView]) {
        let live = (forest(pid)?.branches ?? []).filter { $0.st.ship != .landed }
        let flying = { (v: BranchView) in v.pr != nil || v.b.pushed != .local }
        return (landedOf(pid), live.filter(flying), live.filter { !flying($0) })
    }

    /// The forest page's rows, top to bottom, for the face it shows.
    public func forestRows(_ pid: String?) -> [String] {
        guard let pid else { return [] }
        if face == .branches { return (forest(pid)?.branches ?? []).map { RowKey.branch($0.b.id) } }
        let s = story(pid)
        return s.landed.map { RowKey.landed($0.id) } + (s.inFlight + s.left).map { RowKey.branch($0.b.id) }
    }

    /// Every live forest by whose move (round 29, P1): focus in your hand order, then the workbench by name, inside each.
    public func moveGroups() -> [(move: Move, projects: [Project])] {
        let f = forests()
        let p = projects()
        let live = p.focus + p.workbench
        return Move.allCases.map { mv in (mv, live.filter { (f[$0.id]?.move ?? .waiting) == mv }) }.filter { !$0.projects.isEmpty }
    }

    /// The home's rows: each group's items in the order the page draws them, an open forest's branches under it, then
    /// the archive (or, filtered, only what's ready).
    public func homeRows() -> [String] {
        let p = projects()
        let f = forests()
        var out: [String] = []
        if readyOnly {
            for x in p.focus + p.workbench {
                let ready = f[x.id]?.ready ?? []
                if ready.isEmpty { continue }
                out.append(RowKey.project(x.id))
                out += ready.map { RowKey.branch($0.b.id) }
            }
            return out
        }
        func add(_ xs: [Project]) {
            for x in xs {
                out.append(RowKey.project(x.id))
                if expanded.contains(x.id) { out += (f[x.id]?.branches ?? []).map { RowKey.branch($0.b.id) } }
            }
        }
        let home = homeSections()
        out += home.cards.map(\.key) + reviewRequests.map { RowKey.reviewRequest($0.number) }
        let sections = pushBesideCards(home) ? home.sections.filter { $0.verb == .push } + home.sections.filter { $0.verb != .push } : home.sections
        for item in sections.flatMap(\.items) {
            if case .forest(let x) = item { add([x]) } else { out.append(item.key) }
        }
        add(showArchive ? p.archive : [])
        return out
    }

    /// The home (round 32): a card for each of my open PRs that isn't a draft, in `openPRRows` order (mine to act on
    /// first), then every other item once, grouped by the verb it asks of Phil — review, reply, his other steps, push —
    /// then what others hold and what can't move yet. A forest whose every live branch has a card is said by its cards.
    func homeSections() -> (cards: [OpenPRRow], sections: [HomeSection]) {
        let f = forests()
        let cards = openPRRows()
        let carded = Set(cards.compactMap { $0.branch?.b.id })
        var by: [HomeVerb: [HomeItem]] = [:]
        for g in moveGroups() {
            for p in g.projects {
                guard let fv = f[p.id] else { continue }
                let live = fv.branches.filter { !$0.st.done && $0.b.role != "proof" }
                if !live.isEmpty && live.allSatisfy({ carded.contains($0.b.id) }) { continue }
                if !showParked && !listed(fv) { continue }
                by[verb(fv), default: []].append(.forest(p))
            }
        }
        by[.reply] = replies().map { HomeItem.reply($0.chat, $0.forests) }
        let sections = HomeVerb.allCases.compactMap { v in (by[v] ?? []).isEmpty ? nil : HomeSection(verb: v, items: by[v]!) }
        return (cards, sections)
    }

    /// The only local work the home lists beside the PR cards: every focus forest, whoever's move it is — Phil
    /// committed to it, so it stays to jump back into while an agent holds it and after its chat closes — and any
    /// other forest whose next step is his and that a chat or a tmux pane is on. One an agent or a teammate holds,
    /// however busy, asks nothing of him; one whose step is his but that nothing is on is backlog. Both show with the
    /// archive, and come back by themselves.
    func listed(_ f: ForestView) -> Bool {
        f.p.state == .focus || verb(f).isYours && (!WorkContext.onForest(f.branches).isEmpty
            || f.branches.contains { paneWork.contains("\($0.b.repo)\t\($0.b.name)") })
    }

    /// Whether any listed forest is someone else's move: what the archive's key has to show beyond the archive itself.
    func hasParked() -> Bool {
        let f = forests(), p = projects()
        return (p.focus + p.workbench).compactMap { f[$0.id] }.contains { !$0.closed && !listed($0) }
    }

    /// The branch a forest's line is about: its first live branch at the forest's move.
    func leadBranch(_ f: ForestView) -> BranchView? {
        f.branches.first { !$0.st.done && Move.of($0.st.actor) == f.move }
    }

    /// The verb a forest asks of Phil, from the branch its line is about.
    func verb(_ f: ForestView) -> HomeVerb {
        switch f.move {
        case .moving: return .moving
        case .waiting: return .waiting
        case .done: return .done
        case .yours:
            guard let v = leadBranch(f) else { return .step }
            if v.st.next == "branch.pr" && v.st.ship != .pushed && (v.st.waiting.first?.kind ?? .merge) == .merge { return .merge }
            if ["branch.push.arm", "branch.push.queue", "branch.push.early.arm"].contains(v.st.next ?? "") { return .push }
            return .step
        }
    }

    /// Whether the push chips sit in the top band's right column, under the review requests, instead of a band of
    /// their own: whenever the top band is drawn.
    func pushBesideCards(_ home: (cards: [OpenPRRow], sections: [HomeSection])) -> Bool {
        !home.cards.isEmpty || !reviewRequests.isEmpty
    }

    /// The home's blocks (round 36): my PR cards and the PRs I'm asked to review, as two columns side by side; the
    /// push chips, a row of one-chip columns.
    func homeBlocks() -> [[[String]]] {
        let home = homeSections()
        let top = Self.homeColumns(cards: home.cards.map(\.key), asked: reviewRequests.map { RowKey.reviewRequest($0.number) },
                                   push: home.sections.first { $0.verb == .push }?.items.map(\.key) ?? [])
        return top.isEmpty ? [] : [top]
    }

    /// The home's top as PRCards and PushChips draw it, as columns of rows for j/k (down a column, in reading
    /// order) and h/l (across): my PRs on the left with the review requests and then the push names on the right;
    /// with none of mine open, review and push side by side; with neither cards nor requests, the push names alone.
    /// A column that draws nothing is no column, so h/l never land on an empty one. Pure.
    static func homeColumns(cards: [String], asked: [String], push: [String]) -> [[String]] {
        if cards.isEmpty { return [asked, push].filter { !$0.isEmpty } }
        return [cards, asked + push].filter { !$0.isEmpty }
    }

    /// The open PRs a forest's home row carries, the one at the forest's own move first, then merge order.
    func forestPRs(_ f: ForestView) -> [BranchView] {
        let open = f.closed ? [] : f.branches.filter { $0.pr?.state == "OPEN" }
        return open.filter { Move.of($0.st.actor) == f.move } + open.filter { Move.of($0.st.actor) != f.move }
    }

    /// Chats on a listed forest whose turn ended: each once, newest first, with the forests it's on (round 29). The
    /// reply is owed to the chat, not to each forest it touched.
    func replies() -> [(chat: WorkContext.Chat, forests: [Project])] {
        let p = projects(), f = forests(), t = now.timeIntervalSince1970
        var order: [String] = [], byChat: [String: (chat: WorkContext.Chat, forests: [Project])] = [:]
        for x in p.focus + p.workbench {
            guard let fv = f[x.id], !fv.closed else { continue }
            for c in WorkContext.onForest(fv.branches) where !WorkContext.live(c, now: t) {
                if byChat[c.id] == nil { order.append(c.id); byChat[c.id] = (c, []) }
                byChat[c.id]!.forests.append(x)
            }
        }
        return order.compactMap { byChat[$0] }.sorted { $0.chat.activeAt == $1.chat.activeAt ? $0.chat.id < $1.chat.id : $0.chat.activeAt > $1.chat.activeAt }
    }

    func reply(_ row: String?) -> (chat: WorkContext.Chat, forests: [Project])? {
        guard let id = RowKey.id(row, "y") else { return nil }
        return replies().first { $0.chat.id == id }
    }

    /// Every open PR on a live forest, the home's first rows (round 29, P8): the ones waiting on you, then the ones
    /// others hold, then those still waiting, drafts last; focus forests before the workbench, merge order inside.
    func openPRs() -> [BranchView] {
        let p = projects(), f = forests()
        let all = (p.focus + p.workbench).compactMap { f[$0.id] }.filter { !$0.closed }.flatMap(\.branches).filter { $0.pr?.state == "OPEN" }
        func rank(_ v: BranchView) -> Int { v.pr?.draft == true ? Move.allCases.count : Move.allCases.firstIndex(of: Move.of(v.st.actor))! }
        return all.enumerated().sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }.map(\.element)
    }

    func openPR(_ row: String?) -> BranchView? { RowKey.id(row, "pr").flatMap { branchView($0) } }

    /// The home's open-PR rows: the forests' open PRs and mine no forest carries, in one static order — by number, oldest
    /// first, drafts last — so a PR keeps its place (and its ⌥ digit) while its state changes (round 34).
    func openPRRows() -> [OpenPRRow] {
        let carriedPRs = openPRs()
        var rows: [OpenPRRow] = carriedPRs.map { v in
            let draft = v.pr?.draft == true
            return OpenPRRow(
                key: RowKey.openPR(v.b.id), number: v.pr?.number ?? 0, title: v.pr?.title ?? v.b.description,
                place: forest(v.b.project)?.p.name ?? "", says: draft ? "draft" : ShipRules.says(v.st, v.b, v.pr),
                yours: v.st.actor == .you && !draft, draft: draft, glyph: v.st.ship.glyph, branch: v, mine: nil,
                signals: v.pr.flatMap { prSignals[$0.number] })
        }
        let carried = Set(carriedPRs.compactMap { $0.pr?.number })
        for p in myPRs where !carried.contains(p.number) {
            let merge = (p.approvals ?? 0) > 0 && p.mergeState == "CLEAN"
            let move: Move = p.changesRequested == true || merge ? .yours : .moving
            let says = p.draft ? "draft" : p.changesRequested == true ? "changes requested" : merge ? "merge it" : "waiting on review"
            rows.append(OpenPRRow(
                key: RowKey.myPR(p.number), number: p.number, title: p.title, place: p.local ? p.head : "on GitHub", says: says,
                yours: move == .yours && !p.draft, draft: p.draft, glyph: p.draft ? "○" : "◇", branch: nil, mine: p, signals: prSignals[p.number]))
        }
        return rows.sorted { $0.draft != $1.draft ? !$0.draft : $0.number < $1.number }
    }

    func myPR(_ row: String?) -> MyPR? {
        guard let n = RowKey.id(row, "gh").flatMap(Int.init) else { return nil }
        return myPRs.first { $0.number == n }
    }

    /// Re-read my open PRs (the server answers from its open-PR listing); a failed read keeps the last list.
    public func loadMyPRs() async {
        guard let got = try? await transport.getJSON("/my-prs", as: [MyPR].self) else { return }
        if got != myPRs { myPRs = got }
    }

    func setMyPRs(_ ps: [MyPR]) { myPRs = ps }

    /// Re-read my open PRs' row icons; a failed read keeps the last ones.
    public func loadPRSignals() async {
        guard let got = try? await transport.getJSON("/pr-signals", as: [String: PRSignals].self) else { return }
        let byNumber = Dictionary(uniqueKeysWithValues: got.compactMap { k, v in Int(k).map { ($0, v) } })
        if byNumber != prSignals { prSignals = byNumber }
    }

    func setPRSignals(_ s: [Int: PRSignals]) { prSignals = s }

    public func reviewRequest(_ row: String?) -> ReviewRequest? {
        guard let n = RowKey.id(row, "r").flatMap(Int.init) else { return nil }
        return reviewRequests.first { $0.number == n }
    }

    /// Re-read the review queue. The server answers from its cache and re-searches GitHub behind it,
    /// so asking often is cheap; a failed read keeps the last queue rather than blanking the section.
    public func loadReviewRequests() async {
        guard let got = try? await transport.getJSON("/review-requests", as: [ReviewRequest].self) else { return }
        if got != reviewRequests { reviewRequests = got }
    }

    // ── watchClosings: a forest whose last PR lands gets its moment, then folds into the archive ──

    public func closedIDs() -> Set<String> { Set(forests().values.filter(\.closed).map(\.p.id)) }

    public func syncClosings(after: TimeInterval = 2.6) {
        guard store.ready else { return }
        let closed = closedIDs()
        guard let was = wasClosed else {
            shelved = closed
            wasClosed = closed
            archiveDone(closed)
            return
        }
        // a shelved forest that grows a new branch is open again, so it comes back out
        if shelved.contains(where: { !closed.contains($0) }) { shelved = shelved.filter { closed.contains($0) } }
        for id in closed where !was.contains(id) {
            closing.insert(id)
            scheduler.after(after) { [weak self] in
                guard let self else { return }
                self.closing.remove(id)
                self.shelved.insert(id)
                self.expanded.remove(id)
                if self.launching == id { self.launching = nil }
                self.archiveDone([id])
            }
        }
        wasClosed = closed
    }

    /// A closed forest archives itself once its work is done: every PR landed and nothing left
    /// open on its own list — a forest that closed while canopy was shut goes on the next look.
    func archiveDone(_ ids: Set<String>) {
        let open = Set(store.list(TodoItem.self).filter { ![.done, .dropped, .broken].contains($0.state) }.compactMap(\.project))
        for id in ids.sorted() where store.view(Project.self, id)?.state != .archive && !open.contains(id) { archive?(id) }
    }

    // ── integrate.ts: does the whole forest merge? ──

    func stampOf(_ pid: String) -> String { (forest(pid)?.branches ?? []).map { "\($0.b.name)@\($0.b.tip)" }.joined(separator: "|") }

    /// A forest has a whole to integrate once it spans more than one branch and isn't all landed.
    public func integratable(_ pid: String?) -> Bool {
        let bs = forest(pid)?.branches ?? []
        return bs.count > 1 && bs.contains { $0.st.ship != .landed }
    }

    /// The verdict for the forest as it stands now, if one was asked for this shape.
    public func verdict(_ pid: String?) -> IntegrationVerdict? {
        guard let pid, let v = verdicts[pid], v.stamp == stampOf(pid) else { return nil }
        return v
    }

    struct IntegrateAnswer: Decodable { var ok: Bool; var clean: Bool?; var detail: String? }

    /// Ask whether the forest merges — once per shape unless `again`; a check in flight isn't doubled.
    /// POST /integrate rebuilds an ephemeral ref, so only the forest page, a resting cursor and
    /// the re-check command ask.
    public func checkIntegration(_ pid: String, again: Bool = false) async {
        guard let p = store.view(Project.self, pid), integratable(pid) else { return }
        let stamp = stampOf(pid)
        let had = verdict(pid)
        if let had, had.state == .checking || !again { return }
        verdicts[pid] = IntegrationVerdict(state: .checking, detail: had?.detail ?? "", stamp: stamp)
        let r = await transport.ask(transport.atRepo(p.repo, "/integrate"), ["project": p.name], as: IntegrateAnswer.self)
        guard verdicts[pid]?.stamp == stamp else { return }
        // a check that never ran is not a conflict: the server merely went away
        verdicts[pid] = IntegrationVerdict(
            state: r == nil || r?.ok == false ? .failed : r?.clean == true ? .clean : .conflicts,
            detail: r == nil ? "the check couldn't run" : (r?.detail ?? ""), stamp: stamp)
    }

    /// Tests set the review queue directly.
    func setReviewRequests(_ rs: [ReviewRequest]) { reviewRequests = rs }

    /// Tests and the stub path set a verdict directly.
    func setVerdict(_ pid: String, _ v: IntegrationVerdict) { verdicts[pid] = v }

    /// Whether ↵ on the branch goes to its PR (or the prefilled compare form): pushed, in review or approved.
    public func opensPR(_ id: String?) -> Bool {
        guard let id, let b = store.view(Branch.self, id) else { return false }
        return ShipRules.action(ShipRules.shipOf(b, store.view(Pr.self, id))) == .pr
    }

    /// model.ts compareUrl: GitHub's compare-and-create form for a branch with no PR yet, its body
    /// prefilled by GET /packet-compare (a 302 to it), on `v.base`. `branch.pr` asks the server for
    /// GitHub's URL first and opens this only when that fails.
    public func compareURL(_ v: BranchView) -> URL { transport.url(comparePath(v)) }

    /// The server path that builds the compare form; `&json=1` answers with GitHub's URL instead of a redirect.
    public func comparePath(_ v: BranchView) -> String {
        transport.atRepo(v.b.repo, "/packet-compare?branch=\(v.b.name.uriComponent)&base=\(v.base.uriComponent)")
    }
}

public extension AppModel {
    /// The forests area's state (ForestModel), made once per window.
    var forestModel: ForestModel {
        state {
            let m = ForestModel(store: store, router: router, transport: transport, scheduler: scheduler)
            m.reads = { [weak self] b in self.map { ShipState.of($0).situationReads($0, b) } ?? SituationReads() }
            m.readsVersion = { [weak self] in self.map { ShipState.of($0).readsVersion } ?? 0 }
            m.archive = { [weak self] id in self?.runner.dispatch("project.archive", via: .auto, target: id) }
            return m
        }
    }
}
