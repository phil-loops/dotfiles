import CanopyCore
import Foundation

// Where each branch stands on its way to main, and what the clock says about pushing now — pure
// (ship.ts), so the tests pin the rules. The facts are the outbox's (srv/outbox.py), derived from the store.

/// A branch's place on its way to main.
public enum ShipState: String, Sendable, CaseIterable {
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
}

/// What an approved PR still waits on.
public struct Waiting: Equatable, Sendable {
    public enum Kind: String, Sendable { case parent, draft, conflicts, ci, behind, checks, merge }
    public var kind: Kind
    public var label: String
}

/// The branch's action on ↵ — one per state.
public enum ShipAction: String, Sendable { case push, pr, open }

/// Everything the pages show about where one branch stands.
public struct Stand: Equatable, Sendable {
    public var ship: ShipState
    public var action: ShipAction?
    /// an approved PR: what it still waits on, first thing first
    public var waiting: [Waiting]
    /// you can act on it right now (the ready filter)
    public var ready: Bool
    /// held for the morning and not yet due
    public var held: Bool
}

/// The parent's standing a child's stand depends on (merge order makes it available first).
public struct ParentStand: Sendable {
    public var ship: ShipState
    public var pr: Pr?
    public var name: String
    public init(ship: ShipState, pr: Pr? = nil, name: String) { self.ship = ship; self.pr = pr; self.name = name }
}

public enum ShipRules {
    public static func shipOf(_ b: Branch, _ pr: Pr?) -> ShipState {
        if pr?.state == "MERGED" { return .landed }
        if pr?.state == "OPEN" { return pr?.review == "APPROVED" ? .approved : .review }
        if b.pushed == .synced && b.commits > 0 { return .pushed }
        return b.gates == .green && b.commits > 0 ? .green : .local
    }

    static func settled(_ s: ShipState?) -> Bool { s == nil || s == .landed }

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

    /// Everything the page shows about one branch, given its parent's standing. `now` decides
    /// whether a hold has come due.
    public static func stand(_ b: Branch, _ pr: Pr?, _ parent: ParentStand?, now: Date) -> Stand {
        let ship = shipOf(b, pr)
        let held = pr == nil && (b.holdUntil.flatMap(parseISO).map { $0 > now } ?? false)
        let waiting = ship == .approved && pr != nil ? waitingOn(pr!, parent) : []
        let parentOnOrigin = parent == nil || (parent!.ship != .local && parent!.ship != .green)
        var ready = false
        switch ship {
        case .green: ready = parentOnOrigin && !held
        case .pushed: ready = !held
        case .approved: ready = waiting.first?.kind != .parent
        default: break
        }
        let action: ShipAction = ship == .green ? .push : [.pushed, .review, .approved].contains(ship) ? .pr : .open
        return Stand(ship: ship, action: action, waiting: waiting, ready: ready, held: held)
    }

    /// Whether `p` can push the branch: commits origin doesn't have, and green gates on this tip —
    /// a first push and follow-ups onto an open PR alike. The server's wards still decide.
    public static func canPush(_ b: Branch, _ pr: Pr?) -> Bool { b.gates == .green && pushableButGates(b, pr) }

    /// Everything a push needs except green gates — where `p` runs them instead.
    public static func pushableButGates(_ b: Branch, _ pr: Pr?) -> Bool {
        if b.pending != nil || b.commits == 0 { return false }
        if b.pushed == .ahead { return b.ahead > 0 }
        return b.pushed == .local && (pr == nil || pr?.state == "OPEN")
    }

    /// The PR's base for a compare link: the parent's branch while it's unlanded, else trunk.
    public static func baseFor(_ b: Branch, _ parent: ParentStand?, trunk: String) -> String {
        if let parent, !settled(parent.ship) { return parent.name }
        return trunk
    }

    /// A forest is closed once every branch in it has landed.
    public static func isClosed(_ ships: [ShipState]) -> Bool { !ships.isEmpty && ships.allSatisfy { $0 == .landed } }
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
