import CanopyCore

/// The branch's line (NAV.md, decided 2026-11-05): every diff the review page shows is the stretch
/// between two points on it — main, the parent, then the tree after each of the branch's commits,
/// oldest first, the last being the tip. The header draws it with the stretch lit; `, h` moves a
/// cursor along it and ↵ ↵ picks the two ends. What the diff covers has this one control.
public struct ReviewLine: Equatable {
    public enum Point: Equatable, Sendable {
        case main, parent, commit(String)
        public var key: String {
            switch self {
            case .main: return "p|main"
            case .parent: return "p|parent"
            case .commit(let s): return "c|\(s)"
            }
        }
    }

    /// What two picked points make the diff cover.
    public enum Choice: Equatable, Sendable {
        case base(ReviewBase)
        /// one commit (`from` nil) or a run of them, both ends included
        case commits(from: String?, to: String)
        case refuse(String)

        /// The page's scope key: nil for a base, "sha" for one commit, "from..to" for a run.
        public var scope: String? {
            guard case .commits(let f, let t) = self else { return nil }
            return f.map { "\($0)..\(t)" } ?? t
        }
    }

    public let points: [Point]
    /// the last point origin holds, when the server said which commits are pushed
    public let origin: Int?
    public var tip: Int { points.count - 1 }
    public var parentIndex: Int { points.firstIndex(of: .parent) ?? 0 }

    /// `commits` as the history reads them, newest first. A branch on main has no separate main point.
    public init(parentIsMain: Bool, commits: [HistoryCommit]) {
        let own = Array(commits.reversed())
        let head: [Point] = parentIsMain ? [.parent] : [.main, .parent]
        points = head + own.map { .commit($0.sha) }
        origin = own.lastIndex { $0.pushed == true }.map { head.count + $0 }
    }

    public func index(key: String) -> Int? { points.firstIndex { $0.key == key } }

    public func index(sha: String) -> Int? {
        points.firstIndex { if case .commit(let s) = $0 { return s.hasPrefix(sha) || sha.hasPrefix(s) } else { return false } }
    }

    func sha(_ i: Int) -> String? {
        guard points.indices.contains(i), case .commit(let s) = points[i] else { return nil }
        return s
    }

    /// The stretch the page shows, as (lo, hi]: the points after lo up to hi. Nil when it isn't on
    /// the line (origin's copy after a rewrite, or a commit not in this history).
    public func lit(base: ReviewBase, scope: String?) -> (lo: Int, hi: Int)? {
        if let scope {
            let ends = Self.ends(scope)
            guard let hi = index(sha: ends.to) else { return nil }
            guard let f = ends.from else { return (hi - 1, hi) }
            return index(sha: f).map { ($0 - 1, hi) }
        }
        switch base {
        case .parent: return (parentIndex, tip)
        case .main: return (0, tip)
        case .outgoing: return origin.map { ($0, tip) }
        }
    }

    /// A scope key's ends: "a..b" or a lone "b".
    public static func ends(_ scope: String) -> (from: String?, to: String) {
        guard let r = scope.range(of: "..") else { return (nil, scope) }
        return (String(scope[..<r.lowerBound]), String(scope[r.upperBound...]))
    }

    /// Two picked points as what the diff covers; the same commit twice is that commit alone.
    public func choose(_ a: Int, _ b: Int) -> Choice {
        let lo = min(a, b), hi = max(a, b)
        guard points.indices.contains(lo), points.indices.contains(hi) else { return .refuse("that isn't on the line") }
        guard let end = sha(hi) else { return .refuse("a stretch ends on a commit") }
        if lo == hi { return .commits(from: nil, to: end) }
        switch points[lo] {
        case .main:
            return hi == tip ? .base(.main) : .refuse("against main the diff runs to the tip")
        case .parent:
            return hi == tip ? .base(.parent) : run(lo + 1, hi)
        case .commit:
            return run(lo + 1, hi)
        }
    }

    private func run(_ first: Int, _ last: Int) -> Choice {
        guard let s = sha(first), let e = sha(last) else { return .refuse("a stretch ends on a commit") }
        return .commits(from: s == e ? nil : s, to: e)
    }

    /// `] h` / `[ h`: one commit, the next or previous from what's lit. From a wider stretch, `] h`
    /// lands on its first commit and `[ h` on its last.
    public func step(from lit: (lo: Int, hi: Int)?, by: Int) -> Choice {
        let first = parentIndex + 1
        guard first <= tip else { return .refuse("no commits of its own") }
        let at: Int
        if let l = lit, l.hi - l.lo == 1, l.lo >= parentIndex, !(l.lo == parentIndex && l.hi == tip) {
            at = l.hi + by
        } else {
            let lo = max(lit?.lo ?? parentIndex, parentIndex)
            at = by > 0 ? lo + 1 : (lit?.hi ?? tip)
        }
        if at < first { return .refuse("already on the first commit") }
        if at > tip { return .refuse("already on the last commit") }
        return run(at, at)
    }
}
