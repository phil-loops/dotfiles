import CanopyCore
import Foundation
import Observation

/// words.ts: a branch's commits as /outline tells them, and the edits waiting to be saved — the
/// review page's words (above the diff) and the forest page's share it. One per window
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
    /// what's waiting for a branch's words to be read (`whenShown`)
    @ObservationIgnored private var waiting: [String: [@MainActor () -> Void]] = [:]

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

    /// Who owns the landing title and why. While the opening commit can be reworded it does — the PR
    /// title defaults to its subject and the drafted body to its why — so editing them rewords it
    /// and nothing else holds a second copy. Once it's pushed, the PR text on file does. Nil once
    /// GitHub holds the PR's words.
    public enum LandingOwner: Equatable {
        case commit(String)
        case prText
    }

    public static func landingOwner(_ o: WordsOutline?) -> LandingOwner? {
        guard let o, o.draft != nil, !githubOwns(o.pr) else { return nil }
        if let c = o.commits.first(where: { !$0.carried }), c.locked.isEmpty { return .commit(c.sha) }
        return .prText
    }

    public func landingOwner(_ id: String) -> LandingOwner? { Self.landingOwner(shown[id]) }

    /// The opening commit, when it owns the landing words.
    func owningCommit(_ id: String) -> OutlineCommit? {
        guard case .commit(let sha) = landingOwner(id) else { return nil }
        return shown[id]?.commits.first { $0.sha == sha }
    }

    /// The landing title and body on file: the last save's, else /outline's.
    public func prOnFile(_ id: String) -> MessageWords {
        if let s = savedPr[id] { return s }
        let d = shown[id]?.draft
        return MessageWords(subject: d?.title ?? "", body: d?.body ?? "")
    }

    /// The landing title and body as they stand: the draft edit if there is one, else what's on file.
    public func prValue(_ id: String) -> MessageWords {
        if let c = owningCommit(id) {
            let v = valueOf(id, c)
            return MessageWords(subject: v.subject, body: OutlineHints.joinTemplate(v.body, OutlineHints.splitTemplate(prOnFile(id).body).template))
        }
        return drafts[id]?[Self.pr] ?? prOnFile(id)
    }

    /// PR text saved in config that the owning commit would silently lose to: what it says, when it
    /// differs from the commit's words.
    public func prTextOverride(_ id: String) -> MessageWords? {
        guard let c = owningCommit(id), let d = shown[id]?.draft, d.titleSaved || d.bodySaved else { return nil }
        let v = valueOf(id, c)
        let title = d.titleSaved ? trim(d.title) : trim(v.subject)
        let own = d.bodySaved ? trim(OutlineHints.splitTemplate(d.body).own) : trim(v.body)
        return title == trim(v.subject) && own == trim(v.body) ? nil : MessageWords(subject: title, body: own)
    }

    /// An open or merged PR's words live on GitHub; a closed one's don't — the next push opens a new PR.
    public static func githubOwns(_ pr: WordsOutline.PR?) -> Bool { pr?.exists == true && pr?.state != "CLOSED" }

    /// The landing-text fields a save would send (prTitle / prBody), or nil when nothing changed.
    public func prChange(_ id: String) -> (prTitle: String?, prBody: String?)? {
        if let c = owningCommit(id) {
            // rewording the owner retires any PR text on file, so the commit is the one copy
            guard let d = shown[id]?.draft, d.titleSaved || d.bodySaved, changed(id).contains(where: { $0.sha == c.sha }) else { return nil }
            return (d.titleSaved ? "" : nil, d.bodySaved ? "" : nil)
        }
        guard let o = shown[id], o.draft != nil, let w = drafts[id]?[Self.pr], !Self.githubOwns(o.pr) else { return nil }
        let was = prOnFile(id)
        let t = trim(w.subject) != trim(was.subject) ? trim(w.subject) : nil
        let b = trim(w.body) != trim(was.body) ? trim(w.body) : nil
        return t == nil && b == nil ? nil : (t, b)
    }

    public func prHints(_ id: String) -> [WordsHint] {
        guard let o = shown[id], o.draft != nil, !Self.githubOwns(o.pr) else { return [] }
        let w = prValue(id)
        let split = OutlineHints.splitTemplate(w.body)
        return OutlineHints.hintsFor(MessageWords(subject: w.subject, body: ""), opening: true, ticket: o.ticket.flatMap { $0.isEmpty ? nil : $0 }, kind: .title)
            + OutlineHints.bodyHints(split.own) + overrideHints(id) + droppedWhyHints(id, split.own)
    }

    /// A commit-owned why the server won't carry into the PR body (packet.casual_why: over 280
    /// chars or 3 lines), so the PR would open with the template alone.
    private func droppedWhyHints(_ id: String, _ why: String) -> [WordsHint] {
        guard owningCommit(id) != nil else { return [] }
        let lines = why.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard OutlineHints.len(trim(why)) > 280 || lines > 3 else { return [] }
        return [WordsHint(id: "dropped", tone: .warn, text: "too long to open the PR — it starts with the template alone (3 lines, 280 chars)")]
    }

    /// PR text on file that disagrees with the owning commit: say what it says, and offer to take it in.
    private func overrideHints(_ id: String) -> [WordsHint] {
        guard let x = prTextOverride(id) else { return [] }
        let said = x.body.isEmpty ? "“\(x.subject)”" : "“\(x.subject)” · “\(x.body.split(separator: "\n").first ?? "")”"
        return [WordsHint(id: "override", tone: .warn, text: "the PR text on file says \(said) — saving retires it",
                          fix: WordsHint.Fix(label: "take it") { _ in MessageWords(subject: x.subject, body: x.body) })]
    }

    public func editPr(_ id: String, _ w: MessageWords) {
        if let c = owningCommit(id) {
            return editTo(id, c, MessageWords(subject: w.subject, body: OutlineHints.splitTemplate(w.body).own))
        }
        let was = prOnFile(id)
        setDraft(id, Self.pr, w.subject == was.subject && w.body == was.body ? nil : w)
    }

    /// Edits waiting for one save: changed commits, plus the PR text.
    public func pending(_ id: String) -> Int { changed(id).count + (owningCommit(id) == nil && prChange(id) != nil ? 1 : 0) }

    /// Edits for commits the branch no longer has (it moved under them).
    public func orphans(_ id: String) -> Int {
        guard let o = shown[id] else { return 0 }
        return (drafts[id] ?? [:]).keys.filter { $0 != Self.pr && !o.commits.map(\.sha).contains($0) }.count
    }

    // ── reading /outline (Commits.tsx useOutline) ──

    /// Run `f` once the branch's words are read: now if they are, else after the read lands.
    public func whenShown(_ app: AppModel, _ id: String, _ f: @escaping @MainActor () -> Void) {
        if shown[id] != nil { return f() }
        waiting[id, default: []].append(f)
        load(app, id, force: true)
    }

    /// Read the branch's /outline once per tip (and every 1.5s while the server drafts the PR body).
    public func load(_ app: AppModel, _ id: String, force: Bool = false) {
        guard let b = app.store.view(Branch.self, id) else { return }
        let key = "\(b.repo)|\(b.name)|\(b.tip)"
        if !force && reading[id] == key { return }
        reading[id] = key
        let path = app.transport.atRepo(b.repo, "/outline?branch=\(b.name.uriComponent)")
        let t = app.transport
        Task { @MainActor [weak self, weak app] in
            guard let got = try? await t.getJSON(path, as: WordsOutline.self) else {
                guard let self, self.reading[id] == key else { return }
                self.reading[id] = nil
                if self.waiting.removeValue(forKey: id) != nil { app?.runner.say("couldn't read the branch's words") }
                return
            }
            guard let self, self.reading[id] == key else { return }
            self.shown[id] = got
            self.waiting.removeValue(forKey: id)?.forEach { $0() }
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
