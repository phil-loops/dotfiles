import CanopyCore
import SwiftUI

/// LoopStrip.tsx as a rail: a branch's place in the dev loop — words ▸ gates ▸ push ▸ PR ▸ review ▸
/// merged — one short bar per step (done, later), only the step in the way named with what it waits
/// on. The review page passes its words (the PR form's title and body hints) and the words step opens
/// the commits tab; a forest row leaves words out.
public struct LoopStripView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String
    let words: [LoopWord]?
    let size: CGFloat

    public init(branchID: String, words: [LoopWord]? = nil, size: CGFloat = 12) {
        self.branchID = branchID; self.words = words; self.size = size
    }

    public var body: some View {
        if let v = app.forestModel.branchView(branchID) {
            let steps = Loop.steps(v.b, v.pr, v.st, words: words)
            HStack(alignment: .center, spacing: 4) {
                ForEach(steps, id: \.id) { s in
                    if s.state == .now || s.flag == true {
                        named(s).padding(.horizontal, 4)
                    } else {
                        Capsule().fill(color(s.state).opacity(s.state == .later ? 0.35 : 0.8))
                            .frame(width: size * 1.6, height: 3)
                            .help(s.word)
                    }
                }
                if steps.allSatisfy({ $0.state == .done }) {
                    Text("merged").foregroundStyle(theme.patina).padding(.leading, 4)
                }
            }
            .font(Theme.text(size))
        }
    }

    @ViewBuilder private func named(_ s: LoopStep) -> some View {
        let text = Text(s.word).foregroundColor(s.flag == true ? theme.goldLeaf : color(s.state))
            + Text(s.note.map { " \($0)" } ?? "").foregroundColor(theme.inkDim)
        if s.id == .words {
            Button { app.runner.dispatch("review.tab.commits", via: .click) } label: { text }.buttonStyle(.plain)
        } else if let cmd = Loop.command(s.id) {
            // the step in the way is something to do: a label runs its next move
            text.labelTarget(pane: "loop", key: "step:\(branchID):\(s.id.rawValue)", title: s.word, run: RouteTo(cmd, target: branchID))
        } else {
            text
        }
    }

    private func color(_ s: LoopStep.State) -> Color {
        switch s {
        case .now: theme.goldLeaf
        case .done: theme.patina
        case .later: theme.inkFaint
        }
    }
}

/// `<Commits readOnly>` on the forest pages (`e`): the branch's own commits as /outline tells them,
/// each message whole — read through Ship's WordsState, never edited here.
struct CommitWords: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branchID: String

    var body: some View {
        let words = WordsState.of(app)
        VStack(alignment: .leading, spacing: 6) {
            if let o = words.shown[branchID] {
                ForEach(o.commits, id: \.sha) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.subject).foregroundStyle(theme.ink)
                        if !c.body.isEmpty { Text(c.body).foregroundStyle(theme.inkDim) }
                    }
                }
            } else {
                Text("reading the commits…").foregroundStyle(theme.inkFaint)
            }
        }
        .task(id: app.store.view(Branch.self, branchID)?.tip) { words.load(app, branchID) }
    }
}
