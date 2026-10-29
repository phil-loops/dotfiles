import CanopyCore
import Foundation

/// One entry in the Conversation tab's timeline (review/page.ts TimelineItem).
public enum TimelineItem: Equatable {
    case review(Review)
    case comment(Comment)
    case thread(CanopyCore.Thread)

    public var at: String {
        switch self {
        case .review(let r): r.at
        case .comment(let c): c.at
        case .thread(let t): t.comments.first?.at ?? ""
        }
    }

    /// The cursor's key for the card.
    public var key: String {
        switch self {
        case .thread(let t): "t|\(t.id)"
        case .review(let r): "c|r\(r.at)|\(r.author)"
        case .comment(let c): "c|c\(c.at)|\(c.author)"
        }
    }
}

/// The rows Ship's panes walk, as cursor keys:
///   conversation  "c|body", "c|r…"/"c|c…" (a review, a comment), "t|<thread>", "p|<draft item>"
///   history       "h|" (what lands on main), "h|<sha>" (one commit, newest first)
///   words         "w|desc", "w|title", "w|body", "w|s|<sha>" / "w|b|<sha>" (a commit's subject / body)
@MainActor
public enum ShipRows {
    public static func threads(_ app: AppModel, _ id: String) -> [CanopyCore.Thread] {
        guard let b = splitID(id) else { return [] }
        return app.store.list(CanopyCore.Thread.self).filter { $0.repo == b.repo && $0.branch == b.name }
    }

    /// Ledger items GitHub doesn't show yet (drafts, waiting, sending, lost).
    public static func localItems(_ app: AppModel, _ id: String) -> [DraftItem] {
        (app.store.view(Draft.self, id)?.items ?? []).filter { $0.state != .pending && $0.state != .submitted }
    }

    public static func repliesTo(_ app: AppModel, _ id: String, thread: String) -> [DraftItem] {
        localItems(app, id).filter { $0.kind == "reply" && $0.threadId == thread }
    }

    /// The Conversation tab after the PR's body: reviews, comments and threads, oldest first.
    public static func timeline(_ app: AppModel, _ id: String) -> [TimelineItem] {
        guard let cv = app.store.view(Conv.self, id) else { return [] }
        let out: [TimelineItem] = cv.reviews.filter { !$0.body.isEmpty || $0.state != "COMMENTED" }.map { .review($0) }
            + cv.comments.map { .comment($0) } + threads(app, id).map { .thread($0) }
        return out.enumerated().sorted { a, b in
            let x = a.element.at.isEmpty ? "~" : a.element.at, y = b.element.at.isEmpty ? "~" : b.element.at
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    public static func conversation(_ app: AppModel, _ id: String) -> [String] {
        guard app.store.view(Conv.self, id) != nil else { return [] }
        let ship = ShipState.of(app)
        var out = ["c|body"]
        for it in timeline(app, id) {
            out.append(it.key)
            if case .thread(let t) = it, ship.isOpen(t) { out += repliesTo(app, id, thread: t.id).map { "p|\($0.key)" } }
        }
        return out
    }

    public static func history(_ app: AppModel, _ id: String) -> [String] {
        ["h|"] + (ShipState.of(app).historyRows(id) ?? []).map { "h|\($0.sha)" }
    }

    /// The words pane: on the review page, what lands on main (or the one commit the history shows);
    /// `full` (the forest's words face) adds every commit, the body opening under the cursor's.
    public static func words(_ app: AppModel, _ id: String, full: Bool = false) -> [String] {
        let w = WordsState.of(app)
        let ship = ShipState.of(app)
        guard let o = w.shown[id] else { return full ? [] : ["w|desc"] }
        if !full, let sha = ship.commitScope {
            guard let c = o.commits.first(where: { $0.sha.hasPrefix(sha) }), c.locked.isEmpty else { return [] }
            return ["w|s|\(c.sha)", "w|b|\(c.sha)"]
        }
        var out = ["w|desc"]
        if !WordsState.githubOwns(o.pr) { out += ["w|title", "w|body"] }
        guard full else { return out }
        let at = app.cursors["\(app.router.surface.id)/\(wordsPane)"] ?? ""
        for c in o.commits {
            out.append("w|s|\(c.sha)")
            if c.locked.isEmpty && (at == "w|s|\(c.sha)" || at == "w|b|\(c.sha)") { out.append("w|b|\(c.sha)") }
        }
        return out
    }

    static let wordsPane = ShipSeam.wordsPane

    /// "<repo>:<name>" → (repo, name).
    public static func splitID(_ id: String) -> (repo: String, name: String)? {
        guard let cut = id.firstIndex(of: ":") else { return nil }
        return (String(id[..<cut]), String(id[id.index(after: cut)...]))
    }
}
