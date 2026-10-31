import CanopyCore
import SwiftUI

/// The commits tab (Review.tsx History + Commits.tsx): the branch's commits down the side in the
/// order they were written, and what they land on main as at the foot — the sum of them. j/k step
/// through; a commit's words sit over its own diff (`diff`, area B's). Two panes: "history" and
/// "words" (`C-w l`).
public struct CommitsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String
    let diff: AnyView?

    public init(branchID: String, diff: AnyView? = nil) { self.branchID = branchID; self.diff = diff }

    public var body: some View {
        let ship = ShipState.of(app)
        HStack(alignment: .top, spacing: 0) {
            HistoryList(branchID: branchID).frame(width: 300)
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if let sha = ship.commitScope {
                        CommitHead(branchID: branchID, sha: sha)
                    } else {
                        WordsEditor(branchID: branchID, landing: true, landingOnly: true)
                    }
                }
                .padding(.horizontal, 20)
                .fixedSize(horizontal: false, vertical: true)
                if let diff { diff.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .leading) { theme.rule.opacity(0.5).frame(width: 1) }
        }
        .font(Theme.text(12))
        .padding(.leading, 10)
        .task(id: app.store.view(Branch.self, branchID).map(ShipState.historyKey)) {
            ship.loadHistory(app, branchID)
            WordsState.of(app).load(app, branchID)
        }
    }
}

/// The history list: the branch's own commits oldest first, then what they land as.
struct HistoryList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String

    var body: some View {
        let ship = ShipState.of(app)
        let rows = ship.historyRows(branchID)
        let byKey = Dictionary((rows ?? []).map { ("h|\($0.sha)", $0) }, uniquingKeysWith: { a, _ in a })
        let conv = app.store.view(Conv.self, branchID)
        let landing = conv?.title ?? WordsState.of(app).prValue(branchID).subject.shipNonEmpty ?? app.store.view(Branch.self, branchID)?.description
        VStack(alignment: .leading, spacing: 4) {
            PaneList(pane: ShipSeam.historyPane, rows: ShipRows.history(app, branchID)) { key, on in
                let scoped = key == "h|\(ship.commitScope ?? "")"
                if key == "h|" {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("= " + (landing ?? "—")).foregroundStyle(scoped ? theme.goldLeaf : theme.ink).lineLimit(2)
                        Text("on main\(conv.map { " · #" + String($0.number) } ?? "")").font(Theme.text(10.5)).foregroundStyle(theme.inkFaint)
                    }
                    .padding(.top, 6)
                    .overlay(alignment: .top) { theme.rule.opacity(0.6).frame(height: 1).offset(y: -2) }
                } else if let c = byKey[key] {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.subject).foregroundStyle(scoped ? theme.goldLeaf : theme.ink).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(c.sha.prefix(7))
                            Text(c.date.replacingOccurrences(of: "^\\d{4}-", with: "", options: .regularExpression))
                            if c.pushed == false { Text("● local").foregroundStyle(theme.goldLeaf) }
                        }
                        .foregroundStyle(theme.inkFaint)
                        .font(Theme.text(10.5))
                        ForEach(addresses(c.sha), id: \.self) { a in Text("→ \(a)").font(Theme.text(10.5)).foregroundStyle(theme.goldLeaf) }
                    }
                }
            }
            if rows == nil { Text("reading the commits…").foregroundStyle(theme.inkFaint) }
            else if rows?.isEmpty == true { Text("no commits of its own").foregroundStyle(theme.inkFaint) }
        }
    }

    /// The threads a commit declares it addresses, as "author on file:line".
    private func addresses(_ sha: String) -> [String] {
        ShipRows.threads(app, branchID).filter { $0.fixedBy.contains { $0.sha.hasPrefix(sha) } }
            .map { "\($0.comments.first?.author ?? "") on \(shipLeaf($0.path)):\($0.local?.line ?? $0.line ?? 0)" }
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
                if editable { Text("\(app.registry.keyOf("words.edit")) edit").foregroundStyle(theme.goldLeaf.opacity(0.8)) }
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
        let rows = ShipRows.words(app, branchID, full: full)
        VStack(alignment: .leading, spacing: 4) {
            if w.shown[branchID] == nil && landing {
                Text("reading the commits…").foregroundStyle(theme.inkFaint)
            }
            let orphans = w.orphans(branchID)
            if orphans > 0 { Text("\(orphans) edit\(orphans == 1 ? "" : "s") dropped · branch moved").foregroundStyle(theme.inkFaint) }
            let issues = self.issues(rows)
            if !issues.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, x in
                        (Text(x.where_ + " ").foregroundStyle(theme.inkFaint) + Text(Self.short(x.hint)).foregroundStyle(tone(x.hint.tone))
                            + Text(x.hint.fix.map { " \($0.label)" } ?? "").foregroundStyle(theme.inkFaint))
                    }
                }
                .font(Theme.text(11))
            }
            PaneList(pane: ShipSeam.wordsPane, rows: rows) { key, on in row(key, on: on) }
            let pending = w.pending(branchID)
            if pending > 0 {
                HStack(spacing: 10) {
                    KeyButton(title: "save \(pending)", id: "words.submit", gold: true)
                    Text("\(app.registry.keyOf("undo")) undoes").foregroundStyle(theme.inkFaint)
                }
            }
        }
        .task(id: app.store.view(Branch.self, branchID)?.tip) { w.load(app, branchID) }
        .onChange(of: app.insertField) { old, _ in
            // the description saves on leaving it (v2: on ↵ or blur)
            guard old == "words.desc|\(branchID)", let text = ShipState.of(app).describing[branchID] else { return }
            ShipState.of(app).describing[branchID] = nil
            guard Self.oneLine(text) != app.store.view(Branch.self, branchID)?.description else { return }
            if app.registry.command("branch.describe") != nil {
                app.runner.dispatch("branch.describe", via: .key, target: branchID, arg: text)
            } else {
                app.runner.say("the description saves through branch.describe (area A) — not installed")
            }
        }
    }

    /// The description as the server stores it: one line, runs of space folded (srv/outline.py).
    static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private func tone(_ t: WordsHint.Tone) -> Color { t == .error ? theme.ember : t == .warn ? theme.goldLeaf : theme.inkFaint }

    /// Every hint on the shown words, once each: the title's, then each commit's — an opening commit
    /// that is the title says nothing the title didn't.
    private func issues(_ rows: [String]) -> [(where_: String, hint: WordsHint)] {
        let w = WordsState.of(app)
        var out: [(String, WordsHint)] = []
        if landing { for h in w.prHints(branchID) { out.append((h.id == "plan" || h.id == "prose" ? "body" : "title", h)) } }
        let title = w.prValue(branchID).subject.trimmingCharacters(in: .whitespacesAndNewlines)
        for c in w.shown[branchID]?.commits ?? [] where rows.contains("w|s|\(c.sha)") {
            let sameAsTitle = landing && w.valueOf(branchID, c).subject.trimmingCharacters(in: .whitespacesAndNewlines) == title
            for h in w.hintsOf(branchID, c) where !(sameAsTitle && Self.titleHints.contains(h.id)) { out.append((String(c.short.prefix(7)), h)) }
        }
        return out
    }

    /// A hint as the issues line says it: a few words, the fix doing the rest.
    static func short(_ h: WordsHint) -> String {
        let n = h.text.split(separator: " ").first.map(String.init) ?? ""
        let words = ["long": "long (\(n)/\(OutlineHints.subjectLimit))", "plan": "forest block", "wip": "placeholder", "empty": "empty",
                     "scope": "scope", "type": "no type:", "bare": "prefix on a follow-up", "prose": "long body"]
        return words[h.id] ?? h.text
    }

    @ViewBuilder private func row(_ key: String, on: Bool) -> some View {
        let w = WordsState.of(app)
        let ship = ShipState.of(app)
        let o = w.shown[branchID]
        if let r = WordsRow(key) {
            let field = r.field(branchID)
            let writing = app.insertField == field
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label(r, o)).font(Theme.text(10.5)).foregroundStyle(theme.inkFaint).frame(width: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    switch r {
                    case .desc:
                        let saved = app.store.view(Branch.self, branchID)?.description ?? ""
                        if writing {
                            ModalTextField(field, prompt: "one verb-first line",
                                           text: Binding(get: { ship.describing[branchID] ?? saved }, set: { ship.describing[branchID] = $0.replacingOccurrences(of: "\n", with: " ") }))
                        } else {
                            Text(saved.isEmpty ? "—" : saved).foregroundStyle(theme.ink)
                        }
                        let text = ship.describing[branchID] ?? saved
                        HStack(spacing: 8) {
                            if text.range(of: " and ", options: .caseInsensitive) != nil { Text("“and” · a split point?").foregroundStyle(theme.goldLeaf) }
                        }
                        .font(Theme.text(10.5)).foregroundStyle(theme.inkFaint)
                    case .title:
                        let v = w.prValue(branchID)
                        if writing {
                            ModalTextField(field, text: Binding(get: { w.prValue(branchID).subject },
                                                                set: { w.editPr(branchID, MessageWords(subject: $0.replacingOccurrences(of: "\n", with: " "), body: w.prValue(branchID).body)) }))
                        } else { Text(v.subject.isEmpty ? "—" : v.subject).foregroundStyle(theme.ink) }
                    case .body:
                        let parts = OutlineHints.splitTemplate(w.prValue(branchID).body)
                        if writing {
                            ShipTextEditor(field, placeholder: "why — a line or three", text: Binding(
                                get: { OutlineHints.splitTemplate(w.prValue(branchID).body).own },
                                set: { own in
                                    let cur = w.prValue(branchID)
                                    w.editPr(branchID, MessageWords(subject: cur.subject, body: OutlineHints.joinTemplate(own, OutlineHints.splitTemplate(cur.body).template)))
                                }))
                        } else { Text(parts.own.isEmpty ? "why — a line or three" : parts.own).foregroundStyle(parts.own.isEmpty ? theme.inkFaint : theme.inkDim) }
                        if !parts.template.isEmpty { Text("＋ the repo's PR template").font(Theme.text(10.5)).foregroundStyle(theme.inkFaint) }
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
                                    if !c.locked.isEmpty { Text(c.locked).font(Theme.text(10.5)).foregroundStyle(theme.inkFaint) }
                                    else if !v.body.trimmingCharacters(in: .whitespaces).isEmpty && !rowsShowBody(sha) { Text("¶").foregroundStyle(theme.inkFaint) }
                                }
                                ForEach(addresses(v.body), id: \.self) { a in Text("addresses \(a)").font(Theme.text(10.5)).foregroundStyle(theme.goldLeaf) }
                            } else {
                                Text(v.body.isEmpty ? "why" : v.body).foregroundStyle(v.body.isEmpty ? theme.inkFaint : theme.inkDim)
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if on && !writing && WordsCommands.editable(app, branchID, r) {
                    Text("\(app.registry.keyOf("words.edit")) write\(WordsCommands.fixes(app, branchID, key).isEmpty ? "" : " · \(app.registry.keyOf("words.fix")) fix")")
                        .font(Theme.text(10.5)).foregroundStyle(theme.inkFaint)
                }
            }
        }
    }

    private func rowsShowBody(_ sha: String) -> Bool { ShipRows.words(app, branchID, full: landing && !landingOnly).contains("w|b|\(sha)") }

    private func label(_ r: WordsRow, _ o: WordsOutline?) -> String {
        switch r {
        case .desc: "description"
        case .title: "lands as"
        case .body: "why"
        case .subject(let sha): String((o?.commits.first { $0.sha == sha }?.short ?? sha).prefix(7))
        case .commitBody: "  body"
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
