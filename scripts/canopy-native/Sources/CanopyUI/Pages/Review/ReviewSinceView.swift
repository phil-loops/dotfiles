import CanopyCore
import SwiftUI

/// What Phil's last spoken review left for him on this branch: first the items pinned for him here (what's wanted, a
/// link to the line, his own words from the review beside it), then what was done as he asked, folded into one line.
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
                ForEach(items) { item($0, said: Self.said(for: $0, in: since?.branches[branch.name])) }
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

    private func item(_ i: AttentionItem, said: String?) -> some View {
        let stale = i.stale(tip: branch.tip)
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
            if let said { Text("you said: “\(said)”").foregroundStyle(theme.inkFaint).italic().lineLimit(1).truncationMode(.tail).help(said) }
        }
        .opacity(stale ? 0.6 : 1)
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
}
