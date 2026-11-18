import CanopyCore
import Foundation

// Where each branch stands on its way to main, and what the clock says about pushing now — pure
// (ship.ts), so the tests pin the rules. The facts are the outbox's (srv/outbox.py), derived from the store.

/// A branch's place on its way to main.
public enum ShipStage: String, Sendable, CaseIterable, Term {
    case local, green, pushed, review, approved, landed

    public var glyph: String {
        switch self {
        case .local: "○"
        case .green: "●"
        case .pushed: "↑"
        case .review: "◇"
        case .approved: "◆"
        case .landed: "✓"
        }
    }

    public var word: String {
        switch self {
        case .local: "local"
        case .green: "green"
        case .pushed: "pushed"
        case .review: "in review"
        case .approved: "approved"
        case .landed: "landed"
        }
    }

    public var meaning: String? {
        switch self {
        case .local: "not on origin, and the gates aren't green on this tip"
        case .green: "the gates passed on this tip: ready to push"
        case .pushed: "on origin, no PR yet"
        case .review: "its PR is open, waiting on review"
        case .approved: "its PR is approved; the row says what it still waits on"
        case .landed: "its PR merged into main"
        }
    }

    /// The glyph and word a row draws, as the note's word.
    var term: RowName { RowName(word: "\(glyph) \(word)", meaning: meaning) }
}

/// What an approved PR still waits on.
public struct Waiting: Equatable, Sendable {
    public enum Kind: String, Sendable { case parent, draft, conflicts, ci, behind, checks, merge }
    public var kind: Kind
    public var label: String
}

/// The branch's action on ↵ — one per state.
public enum ShipAction: String, Sendable { case push, pr, open }

/// Who holds a branch's next move.
public enum Actor: Equatable, Sendable {
    case you
    /// a tracker item in progress on this branch (its id)
    case agent(String)
    /// the push gates are running on it
    case gates
    /// CI or required checks on its PR
    case ci
    case reviewer
    /// its parent has to move first
    case parent
    /// held for the morning push window
    case clock
    /// a write to it is in flight
    case canopy
    /// still being built: its gates aren't green on this tip (getting them green is the builder's job)
    case building
    /// nothing left to do for its role
    case nobody
    /// the read that would decide isn't in for this tip
    case unknown
}

extension Actor {
    /// the tracker item holding it, when an agent does
    public var agentItem: String? { if case .agent(let id) = self { return id }; return nil }
}

/// What a branch's derivation needs beyond the store: reads made for this tip, nil while not in.
public struct SituationReads: Equatable, Sendable {
    /// the prep route read for this tip ("conform", "additive", …)
    public var prepRoute: String?
    /// whether the prep route above was read for this tip at all
    public var prepRead = false
    /// the force scope read for this tip: eligible, and whether a guard other than gates refuses
    public var force: (eligible: Bool, blocked: Bool)?
    /// a run in progress can be put ahead of others waiting
    public var gatesCanPutNext = false
    /// a tracker item in progress on this branch
    public var agent: String?
    /// whether its agent's turn is running (true), finished and so waiting on you (false), or not observed (nil)
    public var agentRunning: Bool?

    public init(prepRoute: String? = nil, prepRead: Bool = false, force: (eligible: Bool, blocked: Bool)? = nil,
                gatesCanPutNext: Bool = false, agent: String? = nil, agentRunning: Bool? = nil) {
        self.prepRoute = prepRoute; self.prepRead = prepRead; self.force = force; self.gatesCanPutNext = gatesCanPutNext; self.agent = agent
        self.agentRunning = agentRunning
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.prepRoute == b.prepRoute && a.prepRead == b.prepRead && a.force?.eligible == b.force?.eligible && a.force?.blocked == b.force?.blocked
            && a.gatesCanPutNext == b.gatesCanPutNext && a.agent == b.agent && a.agentRunning == b.agentRunning
    }
}

/// Everything the pages show about where one branch stands: one derivation, every surface a projection of it.
public struct Stand: Equatable, Sendable {
    public var ship: ShipStage
    public var action: ShipAction?
    /// an approved PR: what it still waits on, first thing first
    public var waiting: [Waiting]
    /// held for the morning and not yet due
    public var held: Bool
    /// who holds the next move
    public var actor: Actor
    /// the command that is the next step (an arm, never its confirm); nil when there's none to run
    public var next: String?
    /// nothing left to do for its role: landed, or a proof branch with green gates
    public var done: Bool
    /// the tracker item whose agent finished its turn and waits on you
    public var awaiting: String? = nil
    /// you can act on it right now (the ready filter): your move, nothing else
    public var ready: Bool { actor == .you }
}

/// The parent's standing a child's stand depends on (merge order makes it available first).
public struct ParentStand: Sendable {
    public var ship: ShipStage
    public var pr: Pr?
    public var name: String
    public init(ship: ShipStage, pr: Pr? = nil, name: String) { self.ship = ship; self.pr = pr; self.name = name }
}

/// The ship rules, for every page that shows where a branch stands (the forests and Ship's strip).
public enum ShipRules {
    /// Where the branch stands from its own facts and its PR: a merged PR has landed, an open one is in
    /// review (or approved), else synced commits are pushed and green gates on commits are green.
    public static func shipOf(_ b: Branch, _ pr: Pr?) -> ShipStage {
        if pr?.state == "MERGED" { return .landed }
        if pr?.state == "OPEN" { return pr?.review == "APPROVED" ? .approved : .review }
        if b.pushed == .synced && b.commits > 0 { return .pushed }
        return b.gates == .green && b.commits > 0 ? .green : .local
    }

    static func settled(_ s: ShipStage?) -> Bool { s == nil || s == .landed }

    /// What an approved PR still waits on, first thing first — its unlanded parent before its own state.
    public static func waitingOn(_ pr: Pr, _ parent: ParentStand?) -> [Waiting] {
        var out: [Waiting] = []
        if let parent, !settled(parent.ship) {
            out.append(Waiting(kind: .parent, label: parent.pr.map { "parent #\($0.number) to merge" } ?? "\(leaf(parent.name)) to open its PR"))
        }
        if pr.draft { out.append(Waiting(kind: .draft, label: "being a draft")) }
        let ms = (pr.mergeState ?? "").uppercased()
        if pr.mergeable == "CONFLICTING" || ms == "DIRTY" { out.append(Waiting(kind: .conflicts, label: "its conflicts")) }
        else if ms == "UNSTABLE" { out.append(Waiting(kind: .ci, label: "failing CI")) }
        else if ms == "BEHIND" { out.append(Waiting(kind: .behind, label: "catching up with its base")) }
        else if ms == "BLOCKED" && out.isEmpty { out.append(Waiting(kind: .checks, label: "required checks")) }
        if out.isEmpty { out.append(Waiting(kind: .merge, label: "you — merge it")) }
        return out
    }

    /// Everything the page shows about one branch, given its parent's standing and the reads made for its tip.
    /// `now` decides whether a hold has come due.
    public static func stand(_ b: Branch, _ pr: Pr?, _ parent: ParentStand?, now: Date, reads: SituationReads = SituationReads()) -> Stand {
        let ship = shipOf(b, pr)
        let held = pr == nil && (b.holdUntil.flatMap(parseISO).map { $0 > now } ?? false)
        let waiting = ship == .approved && pr != nil ? waitingOn(pr!, parent) : []
        var (actor, next, done) = situation(b, pr, ship: ship, waiting: waiting, parent: parent, held: held, reads: reads)
        var awaiting: String?
        if case .agent(let id) = actor, reads.agentRunning == false { actor = .you; awaiting = id }
        if actor == .you, next == nil, awaiting == nil, b.diverged, reads.force?.blocked == true { next = "branch.sync" }
        return Stand(ship: ship, action: action(ship), waiting: waiting, held: held, actor: actor, next: next, done: done, awaiting: awaiting)
    }

    /// Whose move it is and the one step that makes it, in priority order: a role that's done, a write in flight, an
    /// agent at work, then the push's own route (origin's copy, a force, a catch-up, the push, the gates), then the PR.
    static func situation(_ b: Branch, _ pr: Pr?, ship: ShipStage, waiting: [Waiting], parent: ParentStand?, held: Bool,
                          reads: SituationReads) -> (Actor, String?, Bool) {
        let gatesNext: (Actor, String?, Bool) = b.gates == .running
            ? (.gates, reads.gatesCanPutNext ? "branch.gates.next" : nil, false) : (.building, "branch.gates.run", false)
        if b.role == "proof" {
            if b.gates == .green { return (.nobody, "branch.proof", true) }
            return gatesNext
        }
        if ship == .landed { return (.nobody, nil, true) }
        if b.pending != nil { return (.canopy, nil, false) }
        let (actor, next, done) = route(b, pr, ship: ship, waiting: waiting, parent: parent, held: held, reads: reads, gatesNext: gatesNext)
        if let agent = reads.agent, actor == .you || actor == .building { return (.agent(agent), next, done) }
        return (actor, next, done)
    }

    private static func route(_ b: Branch, _ pr: Pr?, ship: ShipStage, waiting: [Waiting], parent: ParentStand?, held: Bool,
                              reads: SituationReads, gatesNext: (Actor, String?, Bool)) -> (Actor, String?, Bool) {
        if b.diverged {
            // origin rewrote it and has everything local has: origin wins, never a force (tooling-doctor P7, A1)
            if reads.prepRoute == "conform" { return (.you, "branch.conform", false) }
            guard reads.prepRead, let force = reads.force else { return (.unknown, nil, false) }
            if force.eligible { return (.you, "branch.force.arm", false) }
            if force.blocked { return (.you, nil, false) }
            return gatesNext
        }
        // a branch above it moved: the push would be refused, so the catch-up is the next step (A1)
        if b.owes != nil { return (.you, "branch.catchup", false) }
        let parentOnOrigin = parent == nil || (parent!.ship != .local && parent!.ship != .green)
        if canPush(b, pr) {
            if held { return (.clock, "branch.push.arm", false) }
            return parentOnOrigin || pr != nil ? (.you, "branch.push.arm", false) : (.parent, "branch.push.arm", false)
        }
        if pushableButGates(b, pr) { return gatesNext }
        switch ship {
        case .pushed: return held ? (.clock, nil, false) : (.you, "branch.pr", false)
        case .review:
            if pr?.draft == true || pr?.review == "CHANGES_REQUESTED" { return (.you, nil, false) }
            return (.reviewer, nil, false)
        case .approved:
            switch waiting.first?.kind {
            case .parent: return (.parent, nil, false)
            case .checks: return (.ci, nil, false)
            default: return (.you, "branch.pr", false)
            }
        default: return (.nobody, nil, false)
        }
    }

    /// The situation in one sentence: whose move, and the step or the wait — every surface's words for it.
    public static func says(_ st: Stand, _ b: Branch, _ pr: Pr?) -> String {
        switch st.actor {
        case .you:
            if st.awaiting != nil { return "its agent finished a turn — your reply" }
            switch st.next {
            case "branch.push.arm": return "push \(b.pushed == .ahead ? b.ahead : b.commits)"
            case "branch.conform": return "take origin's copy"
            case "branch.force.arm": return "replace origin's copy"
            case "branch.catchup": return "catch up to \(leaf(b.owes ?? b.parent)) first"
            case "branch.sync": return "diverged — sync carries it on top"
            case "branch.pr":
                if st.ship == .pushed { return "open its PR" }
                return st.waiting.first.map { $0.kind == .merge ? "merge it" : "waiting on \($0.label)" } ?? "merge it"
            default:
                if pr?.review == "CHANGES_REQUESTED" { return "changes requested" }
                if pr?.draft == true { return "a draft — mark it ready" }
                return "your move"
            }
        case .agent: return "an agent is on it"
        case .gates: return "gates running"
        case .ci: return "waiting on required checks"
        case .reviewer: return "waiting on review"
        case .parent: return "waiting on \(leaf(b.parent))"
        case .clock: return "held for the morning"
        case .canopy: return "\(b.pending ?? "working")…"
        case .building: return b.gates == .red ? "gates red\(b.redGates.isEmpty ? "" : ": " + b.redGates.joined(separator: ", "))" : "being built — gates \(b.gates == .stale ? "stale" : "not run")"
        case .unknown: return "reading origin…"
        case .nobody:
            if b.role == "proof" && st.done { return "proof run green" }
            return st.done ? "landed" : b.commits == 0 ? "no changes yet" : "up to date"
        }
    }

    /// What ↵ does for a branch at this stage: push it, go to its PR, or open it.
    public static func action(_ ship: ShipStage) -> ShipAction {
        ship == .green ? .push : [.pushed, .review, .approved].contains(ship) ? .pr : .open
    }

    /// Whether `p` can push the branch: commits origin doesn't have, and green gates on this tip
    /// for a first push. A follow-up onto an open PR pushes with its gates advising (gate the
    /// merge, not the push — tooling-doctor P5): CI checks every push to a PR. The server's wards
    /// still decide; a red squawk refuses there.
    public static func canPush(_ b: Branch, _ pr: Pr?) -> Bool {
        (b.gates == .green || gatesAdvise(b, pr)) && pushableButGates(b, pr)
    }

    /// The gates only advise: an additive push onto a PR that's open — origin has the branch,
    /// local only adds to it, and CI runs every gate on what arrives.
    public static func gatesAdvise(_ b: Branch, _ pr: Pr?) -> Bool {
        pr?.state == "OPEN" && b.pushed == .ahead && !b.diverged
    }

    /// Everything a push needs except green gates — where `p` runs them instead.
    public static func pushableButGates(_ b: Branch, _ pr: Pr?) -> Bool {
        if b.pending != nil || b.commits == 0 { return false }
        if b.pushed == .ahead { return b.ahead > 0 }
        return b.pushed == .local && (pr == nil || pr?.state == "OPEN")
    }

    /// The PR's base for a compare link: the parent's branch while it's unlanded, else trunk.
    /// (`ForestModel.branchView(id)?.base` has it worked out for a branch in the store.)
    public static func baseFor(_ b: Branch, _ parent: ParentStand?, trunk: String) -> String {
        if let parent, !settled(parent.ship) { return parent.name }
        return trunk
    }

    /// A forest is closed once every branch it merges has landed; a proof branch rides along and never merges.
    public static func isClosed(_ stands: [(ship: ShipStage, proof: Bool)]) -> Bool {
        let merging = stands.filter { !$0.proof }
        return !merging.isEmpty && merging.allSatisfy { $0.ship == .landed }
    }
}

/// The last path segment of a branch name ("goal-metrics/metrics-job" → "metrics-job").
public func leaf(_ name: String) -> String { name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name }

/// An ISO-8601 instant, with or without fractional seconds.
public func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

public func isoString(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

// ── the clock against the 15:00 PT cliff (srv/outbox.py WINDOW, measured over 2026's PRs) ──

public enum PushWindow {
    public static let cliffHourPT = 15, morningHourPT = 9
    public static let slowH = 18.8, fastH = 3.2
    static let pt: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    public enum Phase: String, Sendable { case open, closing, late, weekend }

    static func isWeekend(_ d: Date) -> Bool {
        let w = pt.component(.weekday, from: d)
        return w == 1 || w == 7
    }

    /// The next weekday morning at `hour` PT — today's if it's still ahead.
    public static func nextMorning(_ now: Date, hour: Int = morningHourPT) -> Date {
        for i in 0..<8 {
            let day = now.addingTimeInterval(Double(i) * 86_400)
            if isWeekend(day) { continue }
            var c = pt.dateComponents([.year, .month, .day], from: day)
            c.hour = hour
            c.minute = 0
            if let at = pt.date(from: c), at > now { return at }
        }
        return now.addingTimeInterval(86_400)
    }

    public static func phaseAt(_ now: Date) -> (phase: Phase, minutesToCliff: Int) {
        let c = pt.dateComponents([.hour, .minute], from: now)
        let minutes = jsRound((Double(cliffHourPT) - (Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60)) * 60)
        if isWeekend(now) { return (.weekend, minutes) }
        if minutes <= 0 { return (.late, minutes) }
        return (minutes <= 60 ? .closing : .open, minutes)
    }

    /// Math.round: halves go up.
    static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    /// "Fri 9am".
    public static func fmtMorning(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = pt.timeZone
        f.dateFormat = "EEE h"
        let a = DateFormatter()
        a.locale = f.locale
        a.timeZone = f.timeZone
        a.dateFormat = "a"
        return f.string(from: d) + a.string(from: d).lowercased()
    }

    /// The push window's one line, or "" while the window is comfortably open.
    public static func line(_ now: Date) -> String {
        let (phase, minutes) = phaseAt(now)
        let slow = jsRound(slowH)
        switch phase {
        case .open: return ""
        case .closing: return "\(minutes)m to 3pm — a PR opened after it takes ~\(slow)h to merge"
        case .late: return "past 3pm — a PR opened now takes ~\(slow)h to merge, ~\(jsRound(fastH))h from \(fmtMorning(nextMorning(now)))"
        case .weekend: return "the weekend — nobody reviews until \(fmtMorning(nextMorning(now)))"
        }
    }
}
