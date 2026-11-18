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
    fileprivate struct CommitKey: Hashable { let branch: String; let sha: String }
    enum PRPart: String, CaseIterable { case title = "prTitle", body = "prBody" }
    fileprivate struct PRKey: Hashable { let branch: String; let part: PRPart }
    struct PRChange { let part: PRPart; let value: String? }
    struct Receipt {
        fileprivate let commits: OwnedValues<CommitKey, MessageWords>.Receipt
        fileprivate let draft: OwnedValues<PRKey, String>.Receipt
        fileprivate let saved: OwnedValues<PRKey, String>.Receipt
        fileprivate let savedKeys: [PRKey]
    }
    private let commitDrafts = OwnedValues<CommitKey, MessageWords>()
    private let prDrafts = OwnedValues<PRKey, String>()
    private let prSaved = OwnedValues<PRKey, String>()

    public var drafts: [String: [String: MessageWords]] {
        var result: [String: [String: MessageWords]] = [:]
        for (key, value) in commitDrafts.values { result[key.branch, default: [:]][key.sha] = value }
        for key in prDrafts.values.keys { result[key.branch, default: [:]][Self.pr] = prValue(key.branch) }
        return result
    }

    public var savedPr: [String: MessageWords] {
        Dictionary(uniqueKeysWithValues: Set(prSaved.values.keys.map(\.branch)).map { ($0, prOnFile($0)) })
    }
    /// The branch a words command acts on off the review page — the forest page's words face sets it (area A).
    public var focus: String?
    @ObservationIgnored private var reading: [String: BranchSource] = [:]
    @ObservationIgnored private var shownSources: [String: BranchSource] = [:]
    @ObservationIgnored private var requests: [String: Int] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored var fetch: (AppModel, BranchSource) async throws -> WordsOutline = { app, source in
        try await app.transport.getJSON(app.transport.atRepo(source.repo, "/outline?branch=\(source.name.uriComponent)"))
    }
    @ObservationIgnored private var pendingPoll: Set<String> = []
    /// what's waiting for a branch's words to be read (`whenShown`)
    private struct Waiter { let current: @MainActor () -> Bool; let run: @MainActor () -> Void }
    @ObservationIgnored private var waiting: [String: [Waiter]] = [:]

    public init() {}

    public static func of(_ app: AppModel) -> WordsState { app.state { WordsState() } }

    public func setShown(_ id: String, _ outline: WordsOutline) {
        tasks.removeValue(forKey: id)?.cancel()
        requests[id] = nil
        reading[id] = nil
        shownSources[id] = nil
        waiting[id] = nil
        shown[id] = outline
    }

    func hasShown(_ app: AppModel, _ id: String) -> Bool {
        shown[id] != nil && (shownSources[id] == nil || shownSources[id] == BranchSource.current(app, id))
    }

    public func setDraft(_ id: String, _ sha: String, _ w: MessageWords?) {
        if sha == Self.pr {
            prDrafts.set(PRKey(branch: id, part: .title), w?.subject)
            prDrafts.set(PRKey(branch: id, part: .body), w?.body)
        } else { commitDrafts.set(CommitKey(branch: id, sha: sha), w) }
    }

    func stageSave(_ id: String, commits: Set<String>, pr: [PRChange]) -> Receipt {
        let keys = pr.map { PRKey(branch: id, part: $0.part) }
        return Receipt(
            commits: commitDrafts.stage(commits.map { .init(key: CommitKey(branch: id, sha: $0), value: nil) }),
            draft: prDrafts.stage(keys.map { .init(key: $0, value: nil) }),
            saved: prSaved.stage(pr.map { .init(key: PRKey(branch: id, part: $0.part), value: $0.value) }),
            savedKeys: keys)
    }

    func stageUndo(_ id: String, fields: Set<PRPart>) -> Receipt {
        let keys = fields.map { PRKey(branch: id, part: $0) }
        return Receipt(commits: commitDrafts.stage([]), draft: prDrafts.stage([]),
                       saved: prSaved.stage(keys.map { .init(key: $0, value: prSaved.values[$0]) }), savedKeys: keys)
    }

    func accept(_ receipt: Receipt, undo: Bool = false) {
        commitDrafts.accept(receipt.commits)
        prDrafts.accept(receipt.draft)
        prSaved.accept(receipt.saved, replacing: undo ? receipt.savedKeys.map { .init(key: $0, value: nil) } : [])
    }

    func rollback(_ receipt: Receipt) {
        commitDrafts.rollback(receipt.commits)
        prDrafts.rollback(receipt.draft)
        prSaved.rollback(receipt.saved)
    }

    /// The edits that would change a commit as it stands now — a draft back to the original isn't one.
    public func changed(_ id: String) -> [(sha: String, subject: String, body: String)] {
        guard let o = shown[id] else { return [] }
        return o.commits.compactMap { c in
            guard c.locked.isEmpty, let w = commitDrafts.values[CommitKey(branch: id, sha: c.sha)] else { return nil }
            let s = trim(w.subject), b = trim(w.body)
            return s != c.subject || b != c.body ? (c.sha, s, b) : nil
        }
    }

    /// A commit's words as they stand: the draft if there is one, else what git has.
    public func valueOf(_ id: String, _ c: OutlineCommit) -> MessageWords {
        commitDrafts.values[CommitKey(branch: id, sha: c.sha)] ?? MessageWords(subject: c.subject, body: c.body)
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
        let d = shown[id]?.draft
        return MessageWords(subject: prSaved.values[PRKey(branch: id, part: .title)] ?? d?.title ?? "",
                            body: prSaved.values[PRKey(branch: id, part: .body)] ?? d?.body ?? "")
    }

    /// The landing title and body as they stand: the draft edit if there is one, else what's on file.
    public func prValue(_ id: String) -> MessageWords {
        if let c = owningCommit(id) {
            let v = valueOf(id, c)
            return MessageWords(subject: v.subject, body: OutlineHints.joinTemplate(v.body, OutlineHints.splitTemplate(prOnFile(id).body).template))
        }
        let saved = prOnFile(id)
        return MessageWords(subject: prDrafts.values[PRKey(branch: id, part: .title)] ?? saved.subject,
                            body: prDrafts.values[PRKey(branch: id, part: .body)] ?? saved.body)
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
        guard let o = shown[id], o.draft != nil, !Self.githubOwns(o.pr) else { return nil }
        let w = prValue(id)
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
            + OutlineHints.bodyHints(split.own) + overrideHints(id)
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
        let current = prValue(id)
        for (part, value, before) in [(PRPart.title, w.subject, current.subject), (.body, w.body, current.body)] {
            let key = PRKey(branch: id, part: part)
            if value != before || prDrafts.values[key] != nil { prDrafts.set(key, value) }
        }
    }

    /// Edits waiting for one save: changed commits, plus the PR text.
    public func pending(_ id: String) -> Int { changed(id).count + (owningCommit(id) == nil && prChange(id) != nil ? 1 : 0) }

    /// Edits for commits the branch no longer has (it moved under them).
    public func orphans(_ id: String) -> Int {
        guard let o = shown[id] else { return 0 }
        return commitDrafts.values.keys.filter { $0.branch == id && !o.commits.map(\.sha).contains($0.sha) }.count
    }

    // ── reading /outline (Commits.tsx useOutline) ──

    func hasWaiter(_ id: String) -> Bool { (waiting[id] ?? []).contains { $0.current() } }

    /// Run an owned action once a current outline has arrived.
    func whenShown(_ app: AppModel, _ id: String, current: @escaping @MainActor () -> Bool, _ run: @escaping @MainActor () -> Void) {
        if hasShown(app, id) { if current() { run() }; return }
        waiting[id] = (waiting[id] ?? []).filter { $0.current() }
        waiting[id, default: []].append(Waiter(current: current, run: run))
        load(app, id)
    }

    /// Read this observed source once, coalescing in-flight requests; force starts a fresh request.
    @discardableResult
    public func load(_ app: AppModel, _ id: String, force: Bool = false) -> Task<Void, Never>? {
        guard let source = BranchSource.current(app, id) else { return nil }
        if !force && reading[id] == source { return tasks[id] }
        tasks[id]?.cancel()
        sequence &+= 1
        let request = sequence
        requests[id] = request
        reading[id] = source
        let fetch = fetch
        let savedSnapshot = prSaved.snapshot()
        let draftSnapshot = prDrafts.snapshot()
        let task = Task { @MainActor [weak self, weak app] in
            guard let app, !Task.isCancelled else { return }
            let result: Result<WordsOutline, Error>
            do {
                let outline = try await fetch(app, source)
                guard outline.branch == source.name, !source.tip.isEmpty, outline.head == source.tip else {
                    throw Refusal("the branch's words named another source")
                }
                result = .success(outline)
            } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, requests[id] == request else { return }
            tasks[id] = nil
            guard BranchSource.current(app, id) == source else {
                reading[id] = nil
                waiting[id] = (waiting[id] ?? []).filter { $0.current() }
                return
            }
            switch result {
            case .failure:
                reading[id] = nil
                let owned = waiting.removeValue(forKey: id) ?? []
                if owned.contains(where: { $0.current() }) { app.runner.say("couldn't read the branch's words") }
            case .success(let outline):
                prSaved.discardUnchanged(savedSnapshot, keys: Set(prSaved.values.keys.filter { $0.branch == id }))
                let satisfied = Set(prDrafts.values.compactMap { key, value -> PRKey? in
                    guard key.branch == id, !prSaved.isPending(key), let draft = outline.draft else { return nil }
                    let returned = key.part == .title ? draft.title : draft.body
                    let onFile = prSaved.values[key] ?? returned
                    return trim(value) == trim(returned) && trim(value) == trim(onFile) ? key : nil
                })
                prDrafts.discardUnchanged(draftSnapshot, keys: satisfied)
                shown[id] = outline
                shownSources[id] = source
                let owned = waiting.removeValue(forKey: id) ?? []
                for waiter in owned where waiter.current() { waiter.run() }
                if outline.draft?.bodyPending == true, !pendingPoll.contains(id) {
                    pendingPoll.insert(id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak app] in
                        guard let self, let app else { return }
                        self.pendingPoll.remove(id)
                        if self.reading[id] == source { self.load(app, id, force: true) }
                    }
                }
            }
        }
        tasks[id] = task
        return task
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
