import Foundation

// The entities /state and /v2/events carry — a port of viewer-solid/src/v2/types.ts (srv/state.py).
// Ids: repo "<repo>", project/branch/pr/conv/draft/viewed "<repo>:<name>", landed
// "<repo>:<project>#<pr>", thread "<repo>:<branch>#<node>", todo "<slug>".

public enum EntityType: String, CaseIterable, Codable, Sendable {
    case repo, project, branch, pr, landed, conv, thread, draft, viewed, todo, warm

    /// The server domain whose patches carry this type (srv/state.py's DOMAINS).
    public var domain: String {
        switch self {
        case .repo, .project, .branch: Domain.git
        case .pr, .landed, .warm: Domain.remote
        case .conv, .thread, .draft, .viewed: Domain.review
        case .todo: Domain.todo
        }
    }
}

public protocol Entity: Codable, Sendable, Identifiable, Equatable where ID == String {
    static var kind: EntityType { get }
}

public struct ProjectState: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let focus: Self = "focus", workbench: Self = "workbench", archive: Self = "archive"
}

public struct Repo: Entity {
    public static let kind = EntityType.repo
    public var id: String
    public var name: String
    public var main: String
    /// the trunk's tip SHA (not its name — that's `main`)
    public var trunk: String
}

public struct Project: Entity {
    public static let kind = EntityType.project
    public var id: String
    public var repo: String
    public var name: String
    public var state: ProjectState
    public var rank: Int?
    public var ticket: String?
    public var summary: String
    /// Who wrote `summary`: "phil" (his own words), "claude" (a draft), "branch" (borrowed from its
    /// first branch's description); nil from a server that doesn't say.
    public var summaryBy: String?
    public var size: Int
}

public struct Pushed: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let local: Self = "local", ahead: Self = "ahead", synced: Self = "synced"
}

public struct Gates: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let green: Self = "green", red: Self = "red", running: Self = "running", stale: Self = "stale", none: Self = "none"
}

public struct Branch: Entity {
    public static let kind = EntityType.branch
    public var id: String
    public var repo: String
    public var name: String
    public var project: String
    public var parent: String
    public var parentId: String?
    public var description: String
    public var subject: String
    public var commits: Int
    /// its own commits' subjects, oldest first
    public var outline: [String]
    public var tip: String
    public var tree: String
    public var pushed: Pushed
    public var ahead: Int
    public var gates: Gates
    public var redGates: [String]
    /// position in its forest's merge order, 1-based
    public var order: Int
    public var holdUntil: String?
    /// commits on origin/main it lacks
    public var behind: Int
    /// its parent's tip isn't in its history
    public var drifted: Bool
    /// the highest link in its chain that is off its parent's tip (srv/state.py); nil when the chain is current
    public var owes: String?
    /// its tracking ref ("" for none, the forest norm)
    public var upstream: String
    public var upstreamBad: Bool
    public var diverged: Bool
    /// stack-proof's mark ("proof"): an e2e/smoke branch that rides the forest and never merges
    public var role: String?
    /// client-only: an optimistic write in flight ("pushing")
    public var pending: String?
    /// a push Phil queued for when the gates go green, standing for this tree (srv/pushintent.py)
    public var pushQueued: Bool?
    /// what every server read about this branch is derived from (its, its parent's and requires' refs
    /// and config, the trunk): a client key on it moves exactly when such a read could change
    public var readStamp: String?
    /// what the branch's diff reads — its, its parent's and its requires' refs and the trunk's, no
    /// config; the diff is keyed on it so a verdict or a flag landing doesn't re-read an unchanged diff
    public var diffStamp: String?
    /// what the last queued push came to, and when (epoch seconds) — shown for an hour on the client's clock
    public var pushSaid: String?
    public var pushSaidAt: Double?
    /// The queued push's outcome while it's news: within an hour of `now`.
    public func pushSaidNow(_ now: Date) -> String? {
        guard let s = pushSaid, let at = pushSaidAt, now.timeIntervalSince1970 - at < 3600 else { return nil }
        return s
    }
}

public struct Pr: Entity {
    public static let kind = EntityType.pr
    public var id: String
    public var repo: String
    public var branch: String
    public var project: String
    public var number: Int
    public var url: String
    public var state: String
    public var review: String?
    public var draft: Bool
    public var base: String?
    public var approvals: Int?
    public var mergeState: String?
    public var mergeable: String?
    public var approvedAt: String?
    public var title: String?
    /// the PR's head commit, and the commit its newest approval saw (nil from a server that doesn't send them)
    public var headSha: String?
    public var approvedSha: String?
}

public struct Landed: Entity {
    public static let kind = EntityType.landed
    public var id: String
    public var repo: String
    public var project: String
    public var pr: Int
    public var title: String
    public var branch: String
    public var at: String
}

// ── the review domain (srv/reviewdesk.py) ──

public struct Comment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var author: String
    public var body: String
    public var at: String
    public var url: String
    /// PENDING while it sits in its author's unsubmitted review
    public var state: String?
    public var commit: String?
    public var hunk: String?
    public var reactions: [String: Int]?
}

public struct Verdict: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let right: Self = "right", wrong: Self = "wrong", partly: Self = "partly", unclear: Self = "unclear"
}

public struct Note: Codable, Sendable, Equatable {
    public struct Evidence: Codable, Sendable, Equatable { public var path: String; public var line: Int; public var why: String }
    public struct Elsewhere: Codable, Sendable, Equatable { public var path: String; public var line: Int; public var branch: String?; public var why: String }
    public var verdict: Verdict
    public var evidence: [Evidence]
    public var elsewhere: [Elsewhere]
    public var cause: String?
    public var draftReply: String?
    public var model: String
    public var at: String
}

public struct Side: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let right: Self = "RIGHT", left: Self = "LEFT"
}

public struct Thread: Entity {
    public static let kind = EntityType.thread
    public struct Local: Codable, Sendable, Equatable { public var line: Int; public var startLine: Int?; public var addressedBy: String? }
    public struct Fix: Codable, Sendable, Equatable { public var sha: String; public var short: String; public var subject: String }
    public var id: String
    public var repo: String
    public var branch: String
    public var pr: Int
    public var node: String
    public var path: String
    /// GitHub's anchor, on the PR head
    public var line: Int?
    public var startLine: Int?
    public var originalLine: Int?
    public var originalStartLine: Int?
    public var side: Side
    public var subject: String
    public var outdated: Bool
    public var resolved: Bool
    public var canResolve: Bool
    public var canUnresolve: Bool
    public var canReply: Bool
    public var comments: [Comment]
    /// the anchor followed to the local tip
    public var local: Local?
    /// commits that declare they address it (an `Addresses: <url>` trailer)
    public var fixedBy: [Fix]
    public var note: Note?
    /// client-only: a suggestion being applied
    public var applying: Bool?
}

public struct Review: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var author: String
    public var state: String
    public var body: String
    public var at: String
    public var url: String
}

public struct Mapping: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let same: Self = "same", walk: Self = "walk", rewritten: Self = "rewritten", behind: Self = "behind", unknown: Self = "unknown"
}

public struct Conv: Entity {
    public static let kind = EntityType.conv
    public struct Pending: Codable, Sendable, Equatable { public var id: String; public var count: Int }
    public struct Unflagged: Codable, Sendable, Equatable {
        public struct Item: Codable, Sendable, Equatable { public var path: String; public var line: Int; public var why: String }
        public var items: [Item]
        public var model: String
        public var at: String
    }
    public var id: String
    public var repo: String
    public var branch: String
    public var number: Int
    public var title: String
    public var body: String
    public var url: String
    public var author: String
    public var state: String
    public var headRef: String
    public var base: String
    public var head: String
    public var tip: String
    public var mapping: Mapping
    /// commits on the PR head the local branch doesn't have
    public var behind: Int
    public var unpushed: [String]
    public var viewer: String
    public var reviews: [Review]
    public var comments: [Comment]
    public var pending: Pending?
    public var unflagged: Unflagged?
    /// epoch seconds (a float on the wire)
    public var at: Double
}

public struct ItemState: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let draft: Self = "draft", waiting: Self = "waiting", sending: Self = "sending", pending: Self = "pending", submitted: Self = "submitted", gone: Self = "gone"
}

/// One thing Phil wrote, in the ledger: a comment on a line (or range), or a reply.
public struct DraftItem: Codable, Sendable, Equatable {
    public var key: String
    /// "comment" | "reply"
    public var kind: String
    public var path: String?
    public var side: Side?
    public var line: Int?
    public var startLine: Int?
    public var thread: String?
    public var threadId: String?
    public var body: String
    public var state: ItemState
    public var waitsFor: [String]
    public var fixFor: String?
    public var waitingFix: Bool?
    public var err: String?
    public var send: Bool
    public var at: String
}

public struct Draft: Entity {
    public static let kind = EntityType.draft
    public var id: String
    public var repo: String
    public var branch: String
    public var items: [DraftItem]
}

/// Per repo: whether sync's first PR read has landed (before it, a missing PR is unknown, not absent).
public struct Warm: Entity {
    public static let kind = EntityType.warm
    public var id: String
    public var prs: Bool
}

/// The change blocks Phil has read on a branch, and those he flagged (srv/viewed.py).
public struct Viewed: Entity {
    public static let kind = EntityType.viewed
    public var id: String
    public var repo: String
    public var branch: String
    /// blocks read
    public var keys: [String]
    /// blocks read and flagged to come back to
    public var flagged: [String]?
    /// each flag and where it was made, for the list of flags (`space !`)
    public var flags: [Flag]?
}

/// A flagged change as it was when flagged: its block key, the file, the line and the changed line's text.
public struct Flag: Codable, Equatable, Sendable {
    public var key: String
    public var at: Int
    public var path: String
    public var line: Int
    public var text: String
}

public struct TodoState: OpenString {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let open: Self = "open", doing: Self = "doing", waiting: Self = "waiting", done: Self = "done", dropped: Self = "dropped", broken: Self = "broken"
}

/// One item of the viewer's own feature tracker (srv/todo.py, ~/.dotfiles/canopy/todo/<id>.md).
public struct TodoItem: Entity {
    public static let kind = EntityType.todo
    public var id: String
    public var title: String
    /// "build" | "fix" | "decide" | "look"
    public var kind: String
    public var state: TodoState
    public var area: String
    /// "<repo>:<stack-project>" when the item is on a forest's own list; nil = the viewer's list
    public var project: String?
    /// "S" | "M" | "L"
    public var size: String
    public var why: String
    public var waiting: String?
    public var blocked_by: [String]?
    public var links: [String]?
    public var rank: Int?
    /// on a forest's list, the branch that solves the item
    public var solved_by: String?
    public var created: String?
    public var updated: String?
    public var body: String
    public var problems: [String]?
    /// The work journal's freshness for this record (srv/workfresh.py); nil when its capture isn't recorded.
    public var work: WorkFreshness?

    public init(id: String, title: String? = nil, kind: String = "build", state: TodoState = .open, area: String = "x", project: String? = nil,
                size: String = "S", why: String = "", waiting: String? = nil, blocked_by: [String]? = nil, links: [String]? = nil, rank: Int? = nil,
                solved_by: String? = nil, created: String? = nil, updated: String? = nil, body: String = "", problems: [String]? = nil,
                work: WorkFreshness? = nil) {
        self.id = id; self.title = title ?? id; self.kind = kind; self.state = state; self.area = area; self.project = project; self.size = size
        self.why = why; self.waiting = waiting; self.blocked_by = blocked_by; self.links = links; self.rank = rank; self.solved_by = solved_by
        self.created = created; self.updated = updated; self.body = body; self.problems = problems; self.work = work
    }

    enum K: String, CodingKey { case id, title, kind, state, area, project, size, why, waiting, blocked_by, links, rank, solved_by, created, updated, body, problems, work }

    /// A file srv/todo.py can't parse arrives as `{id, title, state: "broken", problems, body}`
    /// with no kind/area/size/why; it still decodes, so the tracker's "Can't read" section shows it.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? id
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        state = (try? c.decode(TodoState.self, forKey: .state)) ?? .broken
        area = (try? c.decode(String.self, forKey: .area)) ?? ""
        project = try? c.decode(String.self, forKey: .project)
        size = (try? c.decode(String.self, forKey: .size)) ?? ""
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
        waiting = try? c.decode(String.self, forKey: .waiting)
        blocked_by = try? c.decode([String].self, forKey: .blocked_by)
        links = try? c.decode([String].self, forKey: .links)
        rank = (try? c.decode(Double.self, forKey: .rank)).map { Int($0) }
        solved_by = try? c.decode(String.self, forKey: .solved_by)
        created = try? c.decode(String.self, forKey: .created)
        updated = try? c.decode(String.self, forKey: .updated)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        problems = try? c.decode([String].self, forKey: .problems)
        work = try? c.decode(WorkFreshness.self, forKey: .work)
    }
}

/// A record's work freshness, as the server projects it from the work journal (srv/workfresh.py): bounded facts, each from
/// its own source. `state` is "answered" only when a qualified completion answers the current direction revision and
/// capture coverage is complete now; "pending" when direction it didn't answer exists; "unknown" when coverage isn't
/// complete; "unavailable" when the journal couldn't be read (`reason` says why, and no other fact is claimed).
public struct WorkFreshness: Codable, Sendable, Equatable {
    public struct Latest: Codable, Sendable, Equatable {
        public var text: String
        public var truncated: Bool
        public var source: String
        public var seq: Int?
        public var sourceTime: String?
        public var receivedAt: String
        public init(text: String, truncated: Bool = false, source: String = "show", seq: Int? = nil, sourceTime: String? = nil, receivedAt: String) {
            self.text = text; self.truncated = truncated; self.source = source; self.seq = seq; self.sourceTime = sourceTime; self.receivedAt = receivedAt
        }
        enum CodingKeys: String, CodingKey { case text, truncated, source, seq, sourceTime = "source_time", receivedAt = "received_at" }
    }
    public struct Delivered: Codable, Sendable, Equatable {
        public var revision: Int
        public var boundary: String
        public var state: String
        public var at: String?
        public init(revision: Int, boundary: String = "turn", state: String = "acknowledged", at: String? = nil) {
            self.revision = revision; self.boundary = boundary; self.state = state; self.at = at
        }
    }
    public struct Worker: Codable, Sendable, Equatable {
        public var host: String
        /// "running" | "ended" | "unknown" | "none": observed, never inferred from an open attempt
        public var state: String
        public var outcome: String?
        public init(host: String, state: String, outcome: String? = nil) { self.host = host; self.state = state; self.outcome = outcome }
    }
    public struct Progress: Codable, Sendable, Equatable {
        public var text: String
        public var at: String
        public var deliveredRevision: Int?
        /// "current" | "older" | "earlier-attempt" | "unverified" | a recorded verdict: what this report answers now
        public var basis: String
        public init(text: String, at: String, deliveredRevision: Int? = nil, basis: String) {
            self.text = text; self.at = at; self.deliveredRevision = deliveredRevision; self.basis = basis
        }
        enum CodingKeys: String, CodingKey { case text, at, deliveredRevision = "delivered_revision", basis }
    }

    public var state: String
    public var reason: String?
    public var revision: Int?
    public var latest: Latest?
    /// "source" | "ambiguous" | "none"
    public var order: String?
    public var inForce: Int?
    public var coverage: String?
    public var delivered: Delivered?
    public var worker: Worker?
    public var progress: Progress?
    /// "current" | "historical" | "stale" | "unverified" | "none"
    public var completion: String?
    public var answeredRevision: Int?

    public init(state: String, reason: String? = nil, revision: Int? = nil, latest: Latest? = nil, order: String? = "source", inForce: Int? = nil,
                coverage: String? = "complete", delivered: Delivered? = nil, worker: Worker? = nil, progress: Progress? = nil,
                completion: String? = "none", answeredRevision: Int? = nil) {
        self.state = state; self.reason = reason; self.revision = revision; self.latest = latest; self.order = order; self.inForce = inForce
        self.coverage = coverage; self.delivered = delivered; self.worker = worker; self.progress = progress; self.completion = completion
        self.answeredRevision = answeredRevision
    }

    enum CodingKeys: String, CodingKey {
        case state, reason, revision, latest, order, inForce = "in_force", coverage, delivered, worker, progress, completion
        case answeredRevision = "answered_revision"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        reason = try? c.decode(String.self, forKey: .reason)
        revision = try? c.decode(Int.self, forKey: .revision)
        latest = try? c.decode(Latest.self, forKey: .latest)
        order = try? c.decode(String.self, forKey: .order)
        inForce = try? c.decode(Int.self, forKey: .inForce)
        coverage = try? c.decode(String.self, forKey: .coverage)
        delivered = try? c.decode(Delivered.self, forKey: .delivered)
        worker = try? c.decode(Worker.self, forKey: .worker)
        progress = try? c.decode(Progress.self, forKey: .progress)
        completion = try? c.decode(String.self, forKey: .completion)
        answeredRevision = try? c.decode(Int.self, forKey: .answeredRevision)
    }
}

/// Domains are open strings ("git", "remote", "review", "todo" today): versions are keyed by
/// whatever the server sends, so a new domain flows through without a client change.
public typealias Versions = [String: Int]

public enum Domain {
    public static let git = "git", remote = "remote", review = "review", todo = "todo"
}
