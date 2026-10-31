import CanopyCore
import SwiftUI

// review/Thread.tsx: a conversation at its line (folded like GitHub's when resolved or outdated),
// the second reader's note under it, a draft from the ledger (a comment or a reply not on GitHub
// yet), and the comment box. Area B draws these on the files tab at their lines; the conversation
// pane draws them in its timeline. The cursor row is the thread ("t|<id>") or the item ("p|<key>").

/// "just now", "5m ago", "3h ago", "2d ago".
func shipAgo(_ at: String, now: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let g = ISO8601DateFormatter()
    guard let d = f.date(from: at) ?? g.date(from: at) else { return "" }
    let s = max(0, now.timeIntervalSince(d))
    if s < 90 { return "just now" }
    if s < 5400 { return "\(Int((s / 60).rounded()))m ago" }
    if s < 129600 { return "\(Int((s / 3600).rounded()))h ago" }
    return "\(Int((s / 86400).rounded()))d ago"
}

private let verdictWord: [String: String] = ["right": "right", "wrong": "worth questioning", "partly": "partly right", "unclear": "unclear"]
private let emoji: [String: String] = ["THUMBS_UP": "👍", "THUMBS_DOWN": "👎", "LAUGH": "😄", "HOORAY": "🎉", "CONFUSED": "😕", "HEART": "❤️", "ROCKET": "🚀", "EYES": "👀"]

struct Chip: View {
    @Environment(\.theme) private var theme
    let text: String
    var gold = false
    var ok = false
    var body: some View {
        Text(text).font(Theme.mono(10.5))
            .foregroundStyle(gold ? theme.goldLeaf : ok ? theme.patina : theme.inkDim)
            .padding(.horizontal, 2)
    }
}

/// One review thread. `selected` lights it and shows its keys; `aside` names its file and line.
public struct ThreadView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let id: String
    let selected: Bool
    let aside: Bool

    public init(id: String, selected: Bool, aside: Bool = false) { self.id = id; self.selected = selected; self.aside = aside }

    public var body: some View {
        let ship = ShipState.of(app)
        if let t = app.store.view(CanopyCore.Thread.self, id) {
            let open = ship.isOpen(t)
            let first = t.comments.first
            let by = t.local?.addressedBy
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(open ? "▾" : "▸").foregroundStyle(theme.inkFaint)
                    if !open { Text(first?.author ?? "").foregroundStyle(theme.goldLeaf) }
                    if aside || t.outdated || t.local?.startLine != nil { Text(where_(t)).foregroundStyle(theme.inkFaint) }
                    if !open { Text(Markdown.plain(first?.body ?? "", max: 110)).foregroundStyle(theme.inkDim).lineLimit(1) }
                    if t.comments.count > 1 { Chip(text: "\(t.comments.count - 1) repl\(t.comments.count == 2 ? "y" : "ies")") }
                    if t.resolved { Chip(text: "resolved", ok: true) }
                    if t.outdated { Chip(text: "outdated") }
                    if !t.fixedBy.isEmpty { Chip(text: "fixed in \(t.fixedBy.map(\.short).joined(separator: ", "))", gold: true) }
                    if let by, !t.outdated, t.fixedBy.isEmpty { Chip(text: "changed in \(by.prefix(7))?", gold: true) }
                    if t.applying == true { Chip(text: "applying…", gold: true) }
                    if let n = t.note { Chip(text: "2nd: \(verdictWord[n.verdict.rawValue] ?? n.verdict.rawValue)", gold: n.verdict == .wrong) }
                    Spacer(minLength: 0)
                    if selected { Text(hints(t)).font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint) }
                }
                if open {
                    if t.outdated, let h = first?.hunk {
                        Text(h.components(separatedBy: "\n").suffix(4).joined(separator: "\n")).font(Theme.mono(11)).foregroundStyle(theme.diffInk)
                            .padding(4).frame(maxWidth: .infinity, alignment: .leading).background(theme.diffBg)
                    }
                    let replaces = linesOf(t)
                    ForEach(t.comments) { c in CommentView(c: c, replaces: replaces) }
                    ForEach(ShipRows.repliesTo(app, branchOf(t), thread: t.id), id: \.key) { r in
                        PendingView(item: r, selected: app.selected == "p|\(r.key)")
                    }
                    if case .reply(_, let tid) = ship.composer, tid == t.id { ComposerView() }
                    if let n = t.note { NoteView(thread: t, note: n) }
                }
            }
            .opacity(t.resolved || t.outdated ? 0.85 : 1)
        }
    }

    private func branchOf(_ t: CanopyCore.Thread) -> String { "\(t.repo):\(t.branch)" }

    private func where_(_ t: CanopyCore.Thread) -> String {
        if let l = t.local { return "\(t.path):\(l.startLine.map { "\($0)–" } ?? "")\(l.line)" }
        return "\(t.path):\(t.originalLine.map(String.init) ?? "?")"
    }

    /// The lines a thread sits on at the local tip, as the diff shows them — what a suggestion replaces.
    private func linesOf(_ t: CanopyCore.Thread) -> [String] {
        // once a local commit changed them, the tip's lines aren't what the suggestion replaced
        guard let l = t.local, l.addressedBy == nil else { return [] }
        return ShipState.of(app).host.newLines(app, path: t.path, from: l.startLine ?? l.line, to: l.line)
    }

    private func hints(_ t: CanopyCore.Thread) -> String {
        let k = app.registry.keyOf
        var out = ["\(k("review.fold")) fold", "\(k("review.reply")) reply"]
        if !t.outdated && !t.resolved { out.append("\(k("review.address")) address") }
        if !t.outdated && t.local?.addressedBy == nil && t.comments.contains(where: { $0.body.contains("```suggestion") }) { out.append("\(k("review.apply")) apply") }
        if t.note?.draftReply != nil { out.append("\(k("review.note.insert")) draft") }
        if t.note != nil { out.append("\(k("review.note.toggle")) note") }
        if t.comments.first?.url.isEmpty == false { out.append("\(k("review.resolve")) resolve") }
        return out.joined(separator: " · ")
    }
}

struct CommentView: View {
    @Environment(\.theme) private var theme
    let c: Comment
    let replaces: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(c.author).foregroundStyle(theme.goldLeaf)
                Text(shipAgo(c.at)).foregroundStyle(theme.inkFaint)
                if c.state == "PENDING" { Chip(text: "pending", gold: true) }
            }
            MarkdownView(c.body, replaces: replaces)
            if let r = c.reactions, !r.isEmpty {
                Text(r.sorted { $0.key < $1.key }.map { "\(emoji[$0.key] ?? $0.key) \($0.value)" }.joined(separator: "  ")).foregroundStyle(theme.inkDim)
            }
        }
        .padding(.leading, 14)
    }
}

/// The second reader's note: its verdict, the evidence, where else it applies, a draft reply.
struct NoteView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let thread: CanopyCore.Thread
    let note: Note
    var body: some View {
        let open = ShipState.of(app).unfold["note:\(thread.id)"] ?? false
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("second reader").foregroundStyle(theme.goldDeep)
                Text(verdictWord[note.verdict.rawValue] ?? note.verdict.rawValue).foregroundStyle(note.verdict == .wrong ? theme.ember : theme.patina)
                if !note.elsewhere.isEmpty { Text("· \(note.elsewhere.count) more like it") }
                Text("\(open ? "▾" : "▸") \(app.registry.keyOf("review.note.toggle"))").foregroundStyle(theme.inkFaint)
            }
            if open {
                ForEach(Array(note.evidence.enumerated()), id: \.offset) { _, e in Text("\(e.path):\(e.line) — \(e.why)") }
                if !note.elsewhere.isEmpty {
                    Text("elsewhere").foregroundStyle(theme.inkFaint)
                    ForEach(Array(note.elsewhere.enumerated()), id: \.offset) { _, e in Text("\(e.path):\(e.line)\(e.branch.map { " on \($0)" } ?? "") — \(e.why)") }
                }
                if let c = note.cause { Text("cause").foregroundStyle(theme.inkFaint); Text(c) }
                if let d = note.draftReply { Text("draft reply").foregroundStyle(theme.inkFaint); Text(d).foregroundStyle(theme.ink) }
                Text("— \(note.model)").foregroundStyle(theme.inkFaint)
            }
        }
        .foregroundStyle(theme.inkDim)
        .padding(.leading, 14)
    }
}

/// A ledger item GitHub doesn't show yet: a draft, one waiting on a push, one being sent.
public struct PendingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let item: DraftItem
    let selected: Bool

    public init(item: DraftItem, selected: Bool) { self.item = item; self.selected = selected }

    static let says: [ItemState: String] = [.draft: "draft · only here", .waiting: "waits for a push", .sending: "sending to your pending review…",
                                            .pending: "pending", .submitted: "submitted", .gone: "not on GitHub any more"]

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(ShipSeam.branchID(app).flatMap { app.store.view(Conv.self, $0)?.viewer }.flatMap { $0.isEmpty ? nil : $0 } ?? "you")
                    .foregroundStyle(theme.goldLeaf)
                Chip(text: item.waitingFix == true ? "waits for its fix" : item.state == .waiting ? "waits for push" : Self.says[item.state] ?? item.state.rawValue, gold: true)
                if item.kind == "comment", let s = item.startLine, let l = item.line { Text("lines \(s)–\(l)").foregroundStyle(theme.inkFaint) }
                if let e = item.err { Text(e).foregroundStyle(theme.ember) }
                Spacer(minLength: 0)
                if selected { Text(hint).font(Theme.mono(10.5)).foregroundStyle(theme.inkFaint) }
            }
            MarkdownView(Self.withFix(item, threads: app.store.list(CanopyCore.Thread.self)))
        }
        .padding(.leading, item.kind == "reply" ? 14 : 0)
    }

    private var hint: String {
        var out: [String] = []
        if item.state == .draft { out.append("\(app.registry.keyOf("review.send")) sends to your pending review") }
        if item.state != .sending { out.append("\(app.registry.keyOf("review.pending.remove")) deletes") }
        return out.joined(separator: " · ")
    }

    /// A reply's "{fix}" as the commit that declares its thread now, the sha it'll go out with.
    public static func withFix(_ it: DraftItem, threads: [CanopyCore.Thread]) -> String {
        guard let f = it.fixFor else { return it.body }
        let t = threads.first { $0.comments.first?.url == f }
        return it.body.replacingOccurrences(of: "{fix}", with: t?.fixedBy.first?.short ?? "‹its fix›", options: [], range: it.body.range(of: "{fix}"))
    }
}

/// The comment box, written in insert mode: ↵ / ⌃↵ sends to the pending review (or hands a commit's
/// note to Claude), ⌥↵ is a newline, esc stops writing; then `, d` saves a draft, `, S` inserts a suggestion.
public struct ComposerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        let ship = ShipState.of(app)
        if let c = ship.composer {
            let note = c.noteSha
            let conv = ShipSeam.branchID(app).flatMap { app.store.view(Conv.self, $0) }
            let text = ship.text(c.key)
            let waits: [String] = { if case .reply = c { return Ledger.unpushedIn(text, conv?.unpushed ?? []) }; return [] }()
            let reviewing = (conv?.pending?.count ?? 0) > 0
            let k = app.registry.keyOf
            VStack(alignment: .leading, spacing: 4) {
                if case .line(_, _, let side, let line, let start, _) = c {
                    Text("\(side == .left ? "old " : "")line\(start.map { "s \($0)–\(line)" } ?? " \(line)")").foregroundStyle(theme.inkFaint)
                }
                ShipTextEditor(ReviewCommands.composeField,
                               placeholder: { if case .reply = c { return "Reply…" }; return note.map { "A note for Claude — it fixes \($0.prefix(7))" } ?? "Leave a comment" }(),
                               text: Binding(get: { ship.text(c.key) }, set: { ship.setText(c.key, $0) }))
                HStack(spacing: 10) {
                    if note == nil { Text("\(k("review.compose.suggest")) suggestion").foregroundStyle(theme.inkFaint) }
                    if !waits.isEmpty { Text("names \(waits.map { String($0.prefix(7)) }.joined(separator: ", ")) — it stays a draft until that's on origin").foregroundStyle(theme.goldLeaf) }
                    Spacer(minLength: 0)
                    Text(app.keys.mode == .insert && app.insertField == ReviewCommands.composeField ? "↵ new line · \(app.registry.verbKey(.send)) sends · esc stops writing" : "\(k("review.compose.edit")) writes · esc cancels")
                        .foregroundStyle(theme.inkFaint)
                    if note != nil {
                        KeyButton(title: "Hand to Claude", id: "review.compose.send", gold: true)
                    } else {
                        KeyButton(title: "Save draft", id: "review.compose.draft")
                        KeyButton(title: { if case .reply = c { return "Reply in your review" }; return reviewing ? "Add review comment" : "Start a review" }(),
                                  id: "review.compose.send", gold: true)
                    }
                }
                .font(Theme.mono(11))
            }
            .padding(6)
            .overlay(Rectangle().stroke(app.insertField == ReviewCommands.composeField ? theme.goldDeep : theme.rule, lineWidth: 1))
        }
    }
}

/// A multi-line text box that is focused exactly while insert mode is writing into it — the same
/// rule as the shell's ModalTextField, for bodies where ↵ is a new line.
public struct ShipTextEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    let id: String
    let placeholder: String
    @Binding var text: String

    public init(_ id: String, placeholder: String = "", text: Binding<String>) { self.id = id; self.placeholder = placeholder; self._text = text }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty { Text(placeholder).foregroundStyle(theme.inkFaint).padding(.leading, 5) }
            TextEditor(text: $text)
                .font(Theme.mono(12.5))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 44, maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.ink)
        .onChange(of: app.insertField == id, initial: true) { _, on in focused = on }
    }
}
