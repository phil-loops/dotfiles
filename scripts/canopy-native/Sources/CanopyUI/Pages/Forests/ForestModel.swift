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
/// `armed`, `opened`, `gateShown` and the force scope from here.
@MainActor
@Observable
public final class ForestModel {
    @ObservationIgnored let store: Store
    @ObservationIgnored let router: Router
    @ObservationIgnored let transport: Transport

    // ── ui.ts ──
    public var showArchive = false
    /// closed forests shown in the archive fold (display only — their state stays until archived)
    public var shelved: Set<String> = []
    /// forests whose last PR just landed: the "canopy closed" moment before they fold away
    public var closing: Set<String> = []
    public var expanded: Set<String> = []
    public var readyOnly = false
    /// the branch whose push (or force) waits for its second keypress
    public var armed: String?
    /// the forest being launched: every node pushed and opened, top to bottom
    public var launching: String?
    /// branches whose compare form was opened from here — "waiting for GitHub" until the PR shows
    public var opened: Set<String> = []
    /// branches (and landed chapters, by row key) showing their whole commit messages
    public var wordsOpen: Set<String> = []
    /// the forest-page branch whose description is being edited in its row
    public var describing: String?
    /// the description being typed
    public var draft = ""
    /// the gate whose output the ship strip shows instead of the running one's — "<branch id> <gate>"
    public var gateShown: String?
    /// a forest page's face: its branches as they stand, or the feature's story (remembered)
    public var face: Face = ForestModel.savedFace {
        didSet { UserDefaults.standard.set(face.rawValue, forKey: Self.faceKey) }
    }
    /// the clock stands use to decide whether a hold came due; the pages tick it
    public var now = Date()
    /// g j at a fork: the children the label layer offers (shown only while that layer is up)
    public var childChoice: [String]?

    public private(set) var verdicts: [String: IntegrationVerdict] = [:]
    @ObservationIgnored var wasClosed: Set<String>?
    /// force scopes read per tip (`readForceScope`)
    public private(set) var forceScopes: [String: (key: String, scope: ForceScope?)] = [:]
    @ObservationIgnored var forceRead: Set<String> = []

    public enum Face: String { case branches, story }
    static let faceKey = "v2.forest.face"
    static var savedFace: Face { UserDefaults.standard.string(forKey: faceKey) == "story" ? .story : .branches }

    init(store: Store, router: Router, transport: Transport) {
        self.store = store; self.router = router; self.transport = transport
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

    /// Every forest with its branches in merge order, each knowing where it stands.
    public func forests() -> [String: ForestView] {
        var groups: [String: [Branch]] = [:]
        for b in store.list(Branch.self) { groups[b.project, default: []].append(b) }
        let prs = store.table(Pr.self)
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
                let v = BranchView(b: b, pr: pr, st: ShipRules.stand(b, pr, parent, now: now), base: ShipRules.baseFor(b, parent, trunk: trunk))
                seen[b.id] = v
                return v
            }
            let branches = bs.map { viewOf($0) }
            let live = branches.filter { $0.st.ship != .landed }
            out[p.id] = ForestView(p: p, branches: branches, ready: branches.filter(\.st.ready), unopened: live.filter { $0.pr == nil },
                                   onGitHub: branches.filter { $0.pr != nil }.count, closed: ShipRules.isClosed(branches.map(\.st.ship)))
        }
        return out
    }

    public func forest(_ pid: String?) -> ForestView? { pid.flatMap { forests()[$0] } }

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

    /// The home's rows: forests and the branches of open ones (or, filtered, only what's ready).
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
        for x in p.focus + p.workbench + (showArchive ? p.archive : []) {
            out.append(RowKey.project(x.id))
            if expanded.contains(x.id) { out += (f[x.id]?.branches ?? []).map { RowKey.branch($0.b.id) } }
        }
        return out
    }

    // ── watchClosings: a forest whose last PR lands gets its moment, then folds into the archive ──

    public func closedIDs() -> Set<String> { Set(forests().values.filter(\.closed).map(\.p.id)) }

    public func syncClosings(after: TimeInterval = 2.6) {
        guard store.ready else { return }
        let closed = closedIDs()
        guard let was = wasClosed else {
            shelved = closed
            wasClosed = closed
            return
        }
        // a shelved forest that grows a new branch is open again, so it comes back out
        if shelved.contains(where: { !closed.contains($0) }) { shelved = shelved.filter { closed.contains($0) } }
        for id in closed where !was.contains(id) {
            closing.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                guard let self else { return }
                self.closing.remove(id)
                self.shelved.insert(id)
                self.expanded.remove(id)
                if self.launching == id { self.launching = nil }
            }
        }
        wasClosed = closed
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

    /// Tests and the stub path set a verdict directly.
    func setVerdict(_ pid: String, _ v: IntegrationVerdict) { verdicts[pid] = v }

    // ── the force scope (commands/branch.ts): replace origin's copy while nobody else has read it ──

    func scopeKey(_ id: String) -> String {
        guard let b = store.view(Branch.self, id) else { return "" }
        return "\(b.tip)|\(b.ahead)|\(b.gates.rawValue)"
    }

    /// The force scope read for this tip — nil until read (or when it couldn't be read).
    public func forceScopeOf(_ id: String?) -> ForceScope? {
        guard let id, let s = forceScopes[id], s.key == scopeKey(id) else { return nil }
        return s.scope
    }

    /// Whether the scope for this tip has been read (even if the read failed).
    public func forceScopeRead(_ id: String) -> Bool { forceScopes[id]?.key == scopeKey(id) }

    func putScope(_ id: String, _ key: String, _ scope: ForceScope?) { forceScopes[id] = (key, scope) }

    struct ForceScopeAnswer: Decodable { var forceScope: ForceScope? }

    /// Read the scope once per tip (it asks GitHub, so never on a poll). A run's green shows in
    /// /state a moment before its verdict lands in git config, so a gates ✗ under green gates is
    /// read again, a few times.
    public func readForceScope(_ id: String, tries: Int = 0) {
        guard let b = store.view(Branch.self, id) else { return }
        let key = scopeKey(id)
        if tries == 0 && forceScopes[id]?.key == key { return }
        let path = transport.atRepo(b.repo, "/force-scope?branch=\(b.name.uriComponent)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let d = try? await self.transport.getJSON(path, as: ForceScopeAnswer.self)
            guard self.scopeKey(id) == key else { return }
            self.putScope(id, key, d?.forceScope)
            let early = b.gates == .green && (d?.forceScope?.guards.contains { $0.k == "gates" && !$0.ok } ?? false)
            if early && tries < 4 {
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (tries + 1)))
                self.readForceScope(id, tries: tries + 1)
            }
        }
    }
}

/// GET /force-scope (srv/sync.py force_scope): no PR, or a draft no one else has touched, and gates
/// green on this tree. /force-origin checks it all again; this only says.
public struct ForceScope: Codable, Equatable, Sendable {
    public struct Guard: Codable, Equatable, Sendable { public var k: String; public var label: String; public var ok: Bool }
    public var eligible: Bool
    public var guards: [Guard]
    public var lease: String
    public var prNumber: Int?
    public var prUrl: String?
}

public extension AppModel {
    /// The forests area's state (ForestModel), made once per window.
    var forestModel: ForestModel { state { ForestModel(store: store, router: router, transport: transport) } }
}
