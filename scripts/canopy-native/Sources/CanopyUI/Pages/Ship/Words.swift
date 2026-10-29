import CanopyCore
import Foundation
import Observation

/// words.ts: a branch's commits as /outline tells them, and the edits waiting to be saved — the
/// review page's words (`e`, the commits tab) and the forest page's share it. One per window
/// (`app.state { WordsState() }`); `WordsState.of(app)`.
@MainActor
@Observable
public final class WordsState {
    /// The PR's place in the drafts map: its title and body are one more pair of words.
    public static let pr = "__pr"

    /// the latest /outline read per branch id, so a save acts on exactly what was shown
    public private(set) var shown: [String: WordsOutline] = [:]
    /// unsaved message edits: branch id → commit sha (or `pr`) → words. They outlive the view.
    public var drafts: [String: [String: MessageWords]] = [:]
    /// The landing text a save just wrote, shown in place of /outline's (read again only when the
    /// tip moves, and a PR-text save doesn't move it). Undo puts the previous one back.
    public var savedPr: [String: MessageWords] = [:]
    /// The branch a words command acts on off the review page — the forest page's words face sets it (area A).
    public var focus: String?
    /// /outline reads in flight or done, by "<repo>|<name>|<tip>"
    @ObservationIgnored private var reading: [String: String] = [:]
    @ObservationIgnored private var pendingPoll: Set<String> = []

    public init() {}

    public static func of(_ app: AppModel) -> WordsState { app.state { WordsState() } }

    public func setShown(_ id: String, _ o: WordsOutline) { shown[id] = o }

    public func setDraft(_ id: String, _ sha: String, _ w: MessageWords?) {
        var mine = drafts[id] ?? [:]
        mine[sha] = w
        drafts[id] = mine
    }

    /// The edits that would change a commit as it stands now — a draft back to the original isn't one.
    public func changed(_ id: String) -> [(sha: String, subject: String, body: String)] {
        guard let o = shown[id], let mine = drafts[id] else { return [] }
        return o.commits.compactMap { c in
            guard c.locked.isEmpty, let w = mine[c.sha] else { return nil }
            let s = trim(w.subject), b = trim(w.body)
            return s != c.subject || b != c.body ? (c.sha, s, b) : nil
        }
    }

    /// A commit's words as they stand: the draft if there is one, else what git has.
    public func valueOf(_ id: String, _ c: OutlineCommit) -> MessageWords {
        drafts[id]?[c.sha] ?? MessageWords(subject: c.subject, body: c.body)
    }

    /// v1's live hints for an unpushed commit — the opening commit wants the ticket's scope, follow-ups read bare.
    public func hintsOf(_ id: String, _ c: OutlineCommit) -> [WordsHint] {
        guard let o = shown[id], c.locked.isEmpty else { return [] }
        let opening = o.commits.first { !$0.carried }?.sha
        return OutlineHints.hintsFor(valueOf(id, c), opening: c.sha == opening, ticket: o.ticket.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Record an edit; one that lands back on git's own words stops being a draft.
    public func editTo(_ id: String, _ c: OutlineCommit, _ w: MessageWords) {
        setDraft(id, c.sha, w.subject == c.subject && w.body == c.body ? nil : w)
    }

    /// The landing title and body on file: the last save's, else /outline's.
    public func prOnFile(_ id: String) -> MessageWords {
        if let s = savedPr[id] { return s }
        let d = shown[id]?.draft
        return MessageWords(subject: d?.title ?? "", body: d?.body ?? "")
    }

    /// The landing title and body as they stand: the draft edit if there is one, else what's on file.
    public func prValue(_ id: String) -> MessageWords { drafts[id]?[Self.pr] ?? prOnFile(id) }

    /// An open or merged PR's words live on GitHub; a closed one's don't — the next push opens a new PR.
    public static func githubOwns(_ pr: WordsOutline.PR?) -> Bool { pr?.exists == true && pr?.state != "CLOSED" }

    /// The landing-text fields a save would send (prTitle / prBody), or nil when nothing changed.
    public func prChange(_ id: String) -> (prTitle: String?, prBody: String?)? {
        guard let o = shown[id], o.draft != nil, let w = drafts[id]?[Self.pr], !Self.githubOwns(o.pr) else { return nil }
        let was = prOnFile(id)
        let t = trim(w.subject) != trim(was.subject) ? trim(w.subject) : nil
        let b = trim(w.body) != trim(was.body) ? trim(w.body) : nil
        return t == nil && b == nil ? nil : (t, b)
    }

    public func prHints(_ id: String) -> [WordsHint] {
        guard let o = shown[id], o.draft != nil, !Self.githubOwns(o.pr) else { return [] }
        let w = prValue(id)
        return OutlineHints.hintsFor(MessageWords(subject: w.subject, body: ""), opening: true, ticket: o.ticket.flatMap { $0.isEmpty ? nil : $0 }, kind: .title)
            + OutlineHints.bodyHints(w.body)
    }

    public func editPr(_ id: String, _ w: MessageWords) {
        let was = prOnFile(id)
        setDraft(id, Self.pr, w.subject == was.subject && w.body == was.body ? nil : w)
    }

    /// Edits waiting for one save: changed commits, plus the PR text.
    public func pending(_ id: String) -> Int { changed(id).count + (prChange(id) == nil ? 0 : 1) }

    /// Edits for commits the branch no longer has (it moved under them).
    public func orphans(_ id: String) -> Int {
        guard let o = shown[id] else { return 0 }
        return (drafts[id] ?? [:]).keys.filter { $0 != Self.pr && !o.commits.map(\.sha).contains($0) }.count
    }

    // ── reading /outline (Commits.tsx useOutline) ──

    /// Read the branch's /outline once per tip (and every 1.5s while the server drafts the PR body).
    public func load(_ app: AppModel, _ id: String, force: Bool = false) {
        guard let b = app.store.view(Branch.self, id) else { return }
        let key = "\(b.repo)|\(b.name)|\(b.tip)"
        if !force && reading[id] == key { return }
        reading[id] = key
        let path = app.transport.atRepo(b.repo, "/outline?branch=\(b.name.uriComponent)")
        let t = app.transport
        Task { @MainActor [weak self, weak app] in
            guard let got = try? await t.getJSON(path, as: WordsOutline.self) else { return }
            guard let self, self.reading[id] == key else { return }
            self.shown[id] = got
            if got.draft?.bodyPending == true, !self.pendingPoll.contains(id) {
                self.pendingPoll.insert(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak app] in
                    guard let self, let app else { return }
                    self.pendingPoll.remove(id)
                    if self.reading[id] == key { self.load(app, id, force: true) }
                }
            }
        }
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
