import CanopyCore
import SwiftUI

/// LoopStrip.tsx: a branch's place in the dev loop, one strip — each step done, in the way, or later;
/// the one in the way says what it waits on. The review page passes its words (the PR form's title
/// and body hints) and the words step opens the commits tab; a forest row leaves words out.
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Text("▸").foregroundStyle(theme.inkFaint) }
                    if s.id == .words {
                        Button { app.runner.dispatch("review.tab.commits", via: .click) } label: {
                            (Text("\(s.flag == true ? "" : "✓ ")words").foregroundColor(s.flag == true ? theme.goldLeaf : theme.patina)
                                + Text(s.note.map { " \($0)" } ?? "").foregroundColor(theme.inkDim))
                        }
                        .buttonStyle(.plain)
                    } else if s.state == .now, let cmd = Loop.command(s.id) {
                        // the step in the way is something to do: a label runs its next move
                        stepText(s).labelTarget(pane: "loop", key: "step:\(branchID):\(s.id.rawValue)", title: s.word, run: RouteTo(cmd, target: branchID))
                    } else {
                        stepText(s)
                    }
                }
            }
            .font(Theme.mono(size))
        }
    }

    private func stepText(_ s: LoopStep) -> Text {
                        (Text("\(s.state == .done ? "✓ " : "")\(s.word)").foregroundColor(color(s.state))
                            + Text(s.state == .now ? s.note.map { " \($0)" } ?? "" : "").foregroundColor(theme.inkDim))
    }

    private func color(_ s: LoopStep.State) -> Color {
        switch s {
        case .now: theme.goldLeaf
        case .done: theme.patina
        case .later: theme.inkFaint
        }
    }
}
