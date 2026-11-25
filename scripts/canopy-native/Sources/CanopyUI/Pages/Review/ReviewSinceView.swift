import CanopyCore
import SwiftUI

/// What Phil's last spoken review left for him on this branch, in the page's header: each item pinned for him here
/// on one line (what's wanted, a link to the line), opened into its card over the diff by ↵ on the forest page or
/// `, A` here; then what was done as he asked, folded into one line.
struct ReviewSinceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branch: Branch
    @State private var showDone = false

    var body: some View {
        if let forest = app.store.view(Project.self, branch.project)?.name {
            let since = ReviewSinceStore.of(app).since(repo: branch.repo, forest: forest)
            let items = Attention.of(app).on(repo: branch.repo, forest: forest).filter { $0.branch == branch.name }
            // a stack that exists before anything is read: the reads start from it even while it shows nothing
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item($0, said: Self.said(for: $0, in: since?.branches[branch.name]), base: since?.branches[$0.branch]?.tipThen) }
                if let since { done(since) }
            }
            .font(Theme.text(11.5))
            .frame(minHeight: 0)
            .task(id: branch.project) {
                await ReviewSinceStore.of(app).load(repo: branch.repo, forest: forest)
                await Attention.of(app).start()
            }
        }
    }

    private func item(_ i: AttentionItem, said: String?, base: String?) -> some View {
        let stale = i.stale(tip: branch.tip)
        let att = Attention.of(app)
        let open = att.opened.contains(i.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(i.ask).foregroundStyle(stale ? theme.inkFaint : theme.ember)
                if let place = Self.line(i) {
                    Button(place) { app.open(address: i.address(repo: branch.repo), source: "attention") }
                        .buttonStyle(.plain).foregroundStyle(theme.goldLeaf).help("go to \(i.file ?? "")\(i.line.map { ":\($0)" } ?? "")")
                }
                Text(i.text).foregroundStyle(theme.ink).lineLimit(2)
                if stale { Text("moved since this was written").foregroundStyle(theme.inkFaint) }
            }
            if !open, let said { Text("you said: “\(said)”").foregroundStyle(theme.inkFaint).italic().lineLimit(1).truncationMode(.tail).help(said) }
            Button { if open { att.opened.remove(i.id) } else { att.opened.insert(i.id) } } label: {
                Text(open ? "▾ open over the diff · \(app.registry.keyOf("attention.cards")) folds" : "▸ what you said · what you were looking at · what it is now")
                    .foregroundStyle(theme.inkFaint)
            }
            .buttonStyle(.plain)
        }
        .opacity(stale ? 0.6 : 1)
        .task(id: open ? Attention.cardKey(i, tip: branch.tip) : "") {
            if open { await att.loadCard(i, tip: branch.tip, fallbackBase: base, app: app) }
        }
    }

    /// Everything done as Phil asked, as one quiet line that opens; a tip moved since the answer says only that.
    @ViewBuilder
    private func done(_ since: ReviewSince) -> some View {
        if since.mark(branch.name, tip: branch.tip) == .moved {
            Text("moved since your review was answered").foregroundStyle(theme.inkFaint)
        } else if let e = since.trusted(branch.name, tip: branch.tip) {
            let done = ReviewSince.answers(e).filter { !ReviewSince.needsEyes($0.answer, in: e) }
            if !done.isEmpty {
                Button { showDone.toggle() } label: {
                    Text((showDone ? "▾ " : "▸ ") + "done as you asked").foregroundStyle(theme.inkFaint)
                }
                .buttonStyle(.plain)
                if showDone {
                    ForEach(done, id: \.answer.id) { Text($0.answer.text).foregroundStyle(theme.inkDim).lineLimit(2).padding(.leading, 14) }
                }
            }
        }
    }

    /// The item's place on this page: file:line, the branch being this one.
    static func line(_ i: AttentionItem) -> String? {
        i.file.map { ($0 as NSString).lastPathComponent + (i.line.map { ":\($0)" } ?? "") }
    }

    /// Phil's own words from the review at the item's place, when the review left a note there.
    static func said(for i: AttentionItem, in e: ReviewSince.Entry?) -> String? {
        guard let file = i.file else { return nil }
        // only a note on that very line: his words about one line never stand in for another's
        let at = (e?.notes ?? []).first { $0.file == file && $0.line == i.line }
        return at?.said.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The lines shown around a note: a few before and more after its line, or the file's start for a note on line 1.
    static func window(count: Int, line: Int?) -> [Int] {
        guard count > 0 else { return [] }
        guard let line, line > 1, line <= count else { return Array(1...min(count, 40)) }
        return Array(max(1, line - 6)...min(count, line + 14))
    }

    /// The change's heading, naming the branch it's on when that isn't where the note was made (it went there).
    static func nowTitle(_ i: AttentionItem, note: ReviewNote?) -> String {
        guard let from = note?.branch, from != i.branch else { return "what it is now" }
        return "what it is now · moved from \(leaf(from)) to \(leaf(i.branch))"
    }
}

/// The opened items' cards over the top of the diff (as the guide sits beside it): the point, what Phil said in full,
/// the file as he saw it at that commit, the change to it since. Long, so it scrolls inside itself; the page under it
/// stays put.
struct ReviewCardsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branch: Branch

    var body: some View {
        if let forest = app.store.view(Project.self, branch.project)?.name {
            let att = Attention.of(app)
            let open = att.on(repo: branch.repo, forest: forest).filter { $0.branch == branch.name && att.opened.contains($0.id) }
            if !open.isEmpty {
                GeometryReader { g in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(open) { i in card(i, att.cards[Attention.cardKey(i, tip: branch.tip)]) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: g.size.height * 0.7)
                    .background(theme.vellumNight)
                    .overlay(alignment: .bottom) { theme.vellumEdge.frame(height: 1) }
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                }
                .font(Theme.text(11.5))
            }
        }
    }

    private func card(_ i: AttentionItem, _ c: AttentionCard?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(i.ask).foregroundStyle(theme.ember)
                Text(i.text).foregroundStyle(theme.ink)
            }
            .font(Theme.text(12.5))
            if let c {
                if let note = c.note {
                    section("what you said") {
                        Text(note.text).foregroundStyle(theme.inkDim).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let seen = c.seen { section(Self.seenTitle(note)) { excerpt(seen, at: note.line) } }
                }
                section(ReviewSinceView.nowTitle(i, note: c.note)) { now(c) }
            } else {
                Text("reading…").foregroundStyle(theme.inkFaint)
            }
        }
    }

    @ViewBuilder
    private func now(_ c: AttentionCard) -> some View {
        if c.base == nil {
            Text("your review didn't see this branch, so there is nothing to compare").foregroundStyle(theme.inkFaint)
        } else if let files = c.since {
            if files.isEmpty {
                Text("unchanged since your review").foregroundStyle(theme.inkFaint)
            } else {
                ForEach(files, id: \.path) { f in InlineDiffView(sha: branch.tip, file: parsePatch(f.path, f.patch), stable: false) }
            }
        } else {
            Text("couldn't read the change").foregroundStyle(theme.inkFaint)
        }
    }

    static func seenTitle(_ note: ReviewNote) -> String {
        let file = note.file.map { ($0 as NSString).lastPathComponent } ?? ""
        return "what you were looking at · \(file) at \(String((note.commit ?? "").prefix(7)))"
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.text(10.5)).foregroundStyle(theme.inkFaint).textCase(.uppercase)
            body()
        }
    }

    /// The file around the line Phil was on, that line lit; a note on line 1 is about the file, so its start.
    private func excerpt(_ lines: [String], at line: Int?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ReviewSinceView.window(count: lines.count, line: line), id: \.self) { n in excerptLine(n, lines[n - 1], lit: n == line) }
        }
        .font(Theme.mono(11.5))
        .padding(6)
        .background(theme.vellumRaise)
    }

    private func excerptLine(_ n: Int, _ text: String, lit: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(n)).foregroundStyle(theme.inkFaint).frame(width: 34, alignment: .trailing)
            Text(text.isEmpty ? " " : text).foregroundStyle(lit ? theme.ink : theme.inkDim).lineLimit(1)
        }
        .background(lit ? theme.goldLeaf.opacity(0.12) : Color.clear)
    }
}
