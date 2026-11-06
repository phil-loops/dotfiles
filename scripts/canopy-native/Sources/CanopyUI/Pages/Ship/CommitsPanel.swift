import CanopyCore
import SwiftUI

/// Above the diff: the words of the stretch the branch's line lights, which is the one place they
/// show. One commit: its subject and why. The whole branch, parent to tip: what lands on main, its
/// title and why. Any other stretch has no words of its own. The row that is the page's title (the
/// description, or an open PR's title) is drawn as the title itself, never twice.
struct StretchWords: View {
    @Environment(AppModel.self) private var app
    let branchID: String

    var body: some View {
        Group {
            if let sha = ShipState.wordsCommit(app) {
                CommitHead(branchID: branchID, sha: sha)
            } else if ShipState.of(app).host.wholeBranch {
                WordsEditor(branchID: branchID, landing: true, landingOnly: true)
            }
        }
        .font(Theme.text(12))
        .fixedSize(horizontal: false, vertical: true)
        .task(id: app.store.view(Branch.self, branchID)?.tip) { WordsState.of(app).load(app, branchID) }
    }
}

/// Above a single commit's diff: which commit, its words (editable until it's pushed), the threads it addresses.
struct CommitHead: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String
    let sha: String

    var body: some View {
        let ship = ShipState.of(app)
        let c = ship.historyRows(branchID)?.first { $0.sha == sha }
        let editable = WordsState.of(app).shown[branchID]?.commits.first { $0.sha.hasPrefix(sha) }?.locked.isEmpty == true
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(c?.date ?? "").foregroundStyle(theme.inkFaint)
                if editable {
                    // a hint names keys that work from here: from the diff, i is Helix's, so the words are a pane up first
                    let up = app.pane?.id == reviewDiffPane ? "\(app.registry.verbKey(.paneUp)) " : ""
                    Text("\(up)\(app.registry.keyOf("words.edit")) edit").foregroundStyle(theme.goldLeaf.opacity(0.8))
                }
            }
            .font(Theme.text(11))
            if editable {
                WordsEditor(branchID: branchID, landing: false, landingOnly: false)
            } else {
                Text(c?.subject ?? "").foregroundStyle(theme.ink)
                let why = (c?.body ?? "").replacingOccurrences(of: "(?m)^Addresses:.*$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !why.isEmpty { Text(why).foregroundStyle(theme.inkDim) }
            }
        }
    }
}

/// Commits.tsx: a branch's words, read first and edited in place — what it lands as (the
/// description, the PR's title + why, the repo template folded away), then its commits one line
/// each, a body opening under the cursor's. Every hint sits in one line on top with its fix
/// (`f` on the row). Edits are drafts until one save (⌃↵, words.save) rewrites them all; u undoes.
/// A pane ("words"): `i` (or ↵) writes the row under the cursor, esc stops.
public struct WordsEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String
    let landing: Bool
    let landingOnly: Bool

    /// `landing` shows the description and the PR's words; `landingOnly` leaves the commits out.
    /// With neither, the rows are the commit the history shows.
    public init(branchID: String, landing: Bool, landingOnly: Bool) { self.branchID = branchID; self.landing = landing; self.landingOnly = landingOnly }

    static let titleHints: Set<String> = ["empty", "wip", "long", "scope", "type"]

    public var body: some View {
        let w = WordsState.of(app)
        let full = landing && !landingOnly
        let o = w.shown[branchID]
        // off the forest's words face, the row that is the page title is drawn as the title
        let rows = ShipRows.words(app, branchID, full: full).filter { k in full || !(WordsRow(k).map { Self.isPageTitle($0, o) } ?? false) }
        VStack(alignment: .leading, spacing: 4) {
            if w.shown[branchID] == nil && landing {
                Text("reading the commits…").foregroundStyle(theme.inkFaint)
            }
            let orphans = w.orphans(branchID)
            if orphans > 0 { Text("\(orphans) edit\(orphans == 1 ? "" : "s") dropped · branch moved").foregroundStyle(theme.inkFaint) }
            PaneList(pane: ShipSeam.wordsPane, rows: rows, header: { key in Self.reachHeader(key, rows, o) }) { key, on in row(key, on: on) }
            let pending = w.pending(branchID)
            if pending > 0 {
                HStack(spacing: 10) {
                    KeyButton(title: "save \(pending)", id: "words.submit", gold: true)
                    Text("\(app.registry.keyOf("undo")) undoes").foregroundStyle(theme.inkFaint)
                }
            }
        }
        .task(id: app.store.view(Branch.self, branchID)?.tip) { w.load(app, branchID) }
    }

    /// The description as the server stores it: one line, runs of space folded (srv/outline.py).
    static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private func tone(_ t: WordsHint.Tone) -> Color { t == .error ? theme.ember : t == .warn ? theme.goldLeaf : theme.inkFaint }

    /// A row's own hints — an opening commit that is the title says nothing the title didn't.
    private func hints(_ r: WordsRow) -> [WordsHint] {
        let w = WordsState.of(app)
        switch r {
        case .desc, .commitBody: return []
        case .title: return landing ? w.prHints(branchID).filter { !Self.bodyHints.contains($0.id) } : []
        case .body: return landing ? w.prHints(branchID).filter { Self.bodyHints.contains($0.id) } : []
        case .subject(let sha):
            guard let c = w.shown[branchID]?.commits.first(where: { $0.sha == sha }) else { return [] }
            let title = w.prValue(branchID).subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let sameAsTitle = landing && w.valueOf(branchID, c).subject.trimmingCharacters(in: .whitespacesAndNewlines) == title
            return w.hintsOf(branchID, c).filter { !(sameAsTitle && Self.titleHints.contains($0.id)) }
        }
    }

    static let bodyHints: Set<String> = ["plan", "prose"]

    /// Who can see the words from this row on, said once where it changes.
    static func reachHeader(_ key: String, _ rows: [String], _ o: WordsOutline?) -> Reach? {
        guard let r = WordsRow(key), let here = reach(r, o), let i = rows.firstIndex(of: key) else { return nil }
        let before = rows[..<i].reversed().lazy.compactMap { WordsRow($0).flatMap { reach($0, o) } }.first
        return before == here ? nil : here
    }

    @ViewBuilder private func row(_ key: String, on: Bool) -> some View {
        let w = WordsState.of(app)
        let ship = ShipState.of(app)
        let o = w.shown[branchID]
        if let r = WordsRow(key) {
            let field = r.field(branchID)
            let writing = app.insertField == field
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TermText("words|label|\(key)", Self.label(r, o)).foregroundStyle(theme.inkFaint)
                    .font(Theme.text(10.5)).frame(width: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    switch r {
                    case .desc:
                        let saved = app.store.view(Branch.self, branchID)?.description ?? ""
                        let edit = LineEdit.of(app)
                        if writing {
                            ModalTextField(field, prompt: "one verb-first line", text: edit.binding(field, saved: saved))
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                let shown = edit.text(field, saved: saved)
                                Text(shown.isEmpty ? "—" : shown).foregroundStyle(theme.ink)
                                if edit.unsaved(field, saved: saved) { UnsavedMark() }
                            }
                        }
                        let text = edit.text(field, saved: saved)
                        HStack(spacing: 8) {
                            if text.range(of: " and ", options: .caseInsensitive) != nil { Text("“and” · a split point?").foregroundStyle(theme.goldLeaf) }
                        }
                        .font(Theme.text(10.5)).foregroundStyle(theme.inkFaint)
                    case .title:
                        let v = w.prValue(branchID)
                        if let pr = o?.pr, WordsState.githubOwns(pr) {
                            Text(pr.title ?? "—").foregroundStyle(theme.inkDim)
                        } else if !writing, Self.echoesCommit(o, v.subject) {
                            Text("same as its one commit").foregroundStyle(theme.inkFaint)
                        } else if writing {
                            ModalTextField(field, text: Binding(get: { w.prValue(branchID).subject },
                                                                set: { w.editPr(branchID, MessageWords(subject: $0.replacingOccurrences(of: "\n", with: " "), body: w.prValue(branchID).body)) }))
                        } else { Text(v.subject.isEmpty ? "—" : v.subject).foregroundStyle(theme.ink) }
                    case .body:
                        let github = o?.pr.flatMap { WordsState.githubOwns($0) ? $0 : nil }
                        let parts = OutlineHints.splitTemplate(github?.body ?? w.prValue(branchID).body)
                        if github != nil {
                            Text(parts.own.isEmpty ? "—" : parts.own).foregroundStyle(theme.inkDim)
                        } else if writing {
                            ShipTextEditor(field, placeholder: "why — a line or three", text: Binding(
                                get: { OutlineHints.splitTemplate(w.prValue(branchID).body).own },
                                set: { own in
                                    let cur = w.prValue(branchID)
                                    w.editPr(branchID, MessageWords(subject: cur.subject, body: OutlineHints.joinTemplate(own, OutlineHints.splitTemplate(cur.body).template)))
                                }))
                        } else { Text(parts.own.isEmpty ? "why — a line or three" : parts.own).foregroundStyle(parts.own.isEmpty ? theme.inkFaint : theme.inkDim) }
                    case .subject(let sha), .commitBody(let sha):
                        if let c = o?.commits.first(where: { $0.sha == sha }) {
                            let v = w.valueOf(branchID, c)
                            let isSubject: Bool = { if case .subject = r { return true }; return false }()
                            if writing && isSubject {
                                ModalTextField(field, text: Binding(get: { w.valueOf(branchID, c).subject },
                                                                    set: { w.editTo(branchID, c, MessageWords(subject: $0.replacingOccurrences(of: "\n", with: " "), body: w.valueOf(branchID, c).body)) }))
                            } else if writing {
                                ShipTextEditor(field, placeholder: "why", text: Binding(get: { w.valueOf(branchID, c).body },
                                                                                       set: { w.editTo(branchID, c, MessageWords(subject: w.valueOf(branchID, c).subject, body: $0)) }))
                            } else if isSubject {
                                HStack(spacing: 6) {
                                    Text(v.subject).foregroundStyle(c.locked.isEmpty ? theme.ink : theme.inkDim)
                                    if w.changed(branchID).contains(where: { $0.sha == c.sha }) { Text("edited").font(Theme.text(10.5)).foregroundStyle(theme.goldLeaf) }
                                    if c.locked.isEmpty, !v.body.trimmingCharacters(in: .whitespaces).isEmpty && !rowsShowBody(sha) { Text("¶").foregroundStyle(theme.inkFaint) }
                                }
                                ForEach(addresses(v.body), id: \.self) { a in Text("addresses \(a)").font(Theme.text(10.5)).foregroundStyle(theme.goldLeaf) }
                            } else {
                                Text(v.body.isEmpty ? "why" : v.body).foregroundStyle(v.body.isEmpty ? theme.inkFaint : theme.inkDim)
                            }
                        }
                    }
                    ForEach(Array(hints(r).enumerated()), id: \.offset) { _, h in
                        (Text(h.text).foregroundStyle(tone(h.tone)) + Text(h.fix.map { " · \($0.label)" } ?? "").foregroundStyle(theme.inkFaint))
                            .font(Theme.text(11))
                    }
                }
                Spacer(minLength: 8)
                // the hint keeps its own width whether shown or not, so text wraps before it and the cursor never reflows a row
                Text("\(app.registry.keyOf("words.edit")) write\(WordsCommands.fixes(app, branchID, key).isEmpty ? "" : " · \(app.registry.keyOf("words.fix")) fix")")
                    .font(Theme.text(10.5)).foregroundStyle(theme.inkFaint)
                    .opacity(on && !writing && WordsCommands.editable(app, branchID, r) ? 1 : 0)
            }
        }
    }

    private func rowsShowBody(_ sha: String) -> Bool { ShipRows.words(app, branchID, full: landing && !landingOnly).contains("w|b|\(sha)") }

    /// Whether a row's words are the review page's title (ReviewPage's header): the PR's title once
    /// GitHub has one, the description before.
    static func isPageTitle(_ r: WordsRow, _ o: WordsOutline?) -> Bool {
        let prOpen = o?.pr.map(WordsState.githubOwns) ?? false
        switch r {
        case .desc: return !prOpen
        case .title: return prOpen
        default: return false
        }
    }

    /// Whether the landing title is just the branch's one commit's subject, never saved as its own.
    static func echoesCommit(_ o: WordsOutline?, _ title: String) -> Bool {
        guard let o, o.draft?.titleSaved != true else { return false }
        let own = o.commits.filter { !$0.carried }
        return own.count == 1 && own[0].subject.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces)
    }

    /// Who can see a row's words yet, and so whether they can still change. Nil for a commit's body row.
    static func reach(_ r: WordsRow, _ o: WordsOutline?) -> Reach? {
        switch r {
        case .desc: .onlyHere
        case .title, .body: o?.pr.flatMap { WordsState.githubOwns($0) ? Reach.onPR($0.number ?? 0) : nil } ?? .draft
        case .subject(let sha): (o?.commits.first { $0.sha == sha }).map { $0.locked.isEmpty ? .local : .locked($0.locked) }
        case .commitBody: nil
        }
    }

    /// A words row's name in the label column: what the row is, or the commit's short sha.
    static func label(_ r: WordsRow, _ o: WordsOutline?) -> RowName {
        switch r {
        case .desc: RowName(word: "description", meaning: "description: the branch's one line, for you and canopy")
        case .title: RowName(word: "lands as", meaning: "lands as: the PR title, and main's commit subject after the squash")
        case .body: RowName(word: "why", meaning: "why: your lines above the PR template; they land on main with the squash")
        case .subject(let sha): RowName(word: String((o?.commits.first { $0.sha == sha }?.short ?? sha).prefix(7)), meaning: nil)
        case .commitBody: RowName(word: "  body", meaning: nil)
        }
    }

    /// The threads a body's `Addresses:` trailers name, as "author on file:line".
    private func addresses(_ body: String) -> [String] {
        let threads = ShipRows.threads(app, branchID)
        return body.components(separatedBy: "\n").compactMap { l -> String? in
            guard l.hasPrefix("Addresses:") else { return nil }
            let url = l.dropFirst("Addresses:".count).trimmingCharacters(in: .whitespaces)
            if let t = threads.first(where: { $0.comments.first?.url == url }) {
                return "\(t.comments.first?.author ?? "") on \(shipLeaf(t.path)):\(t.local?.line ?? t.line ?? 0)"
            }
            return url.replacingOccurrences(of: "https://github.com/", with: "")
        }
    }
}

/// Who can see a words row yet: only this machine, the PR once it's opened, or already shared.
enum Reach: Term, Equatable {
    case onlyHere, draft, local
    /// the open PR's words, which GitHub keeps from here on
    case onPR(Int)
    /// shared already; the server's reason it can't be reworded ("on origin", a merge, carried from a dep)
    case locked(String)

    var editable: Bool {
        switch self {
        case .locked, .onPR: false
        default: true
        }
    }

    var word: String {
        switch self {
        case .onlyHere: "only here"
        case .draft: "draft"
        case .local: "local"
        case .onPR(let n): "on #\(n)"
        case .locked(let why): why
        }
    }

    var meaning: String? {
        switch self {
        case .onlyHere: "kept in git config, never sent anywhere"
        case .draft: "becomes the PR's words when you open it"
        case .local: "not pushed yet, so i rewords it"
        case .onPR: "GitHub holds the PR's words now — change them there"
        case .locked(let why): "already shared, so it can't be reworded here"
        }
    }
}

/// A words row's name in the label column, and what the row is.
struct RowName: Term, Equatable {
    var word: String
    var meaning: String?

    func with(word: String) -> RowName { RowName(word: word, meaning: meaning) }
}
