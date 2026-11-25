import CanopyCore
import SwiftUI

/// The branch against Phil's last spoken review: how it stands and why it moved, then each answer beside the note it
/// answers (what he said on hover). A tip moved since the answer was written says only that.
struct ReviewSinceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let branch: Branch

    var body: some View {
        if let forest = app.store.view(Project.self, branch.project)?.name {
            let since = ReviewSinceStore.of(app).since(repo: branch.repo, forest: forest)
            // a stack that exists before anything is read: the read starts from it even while it shows nothing
            VStack(alignment: .leading, spacing: 0) {
                if let since, let mark = since.mark(branch.name, tip: branch.tip) { content(since, mark) }
            }
            .frame(minHeight: 0)
            .task(id: branch.project) { await ReviewSinceStore.of(app).load(repo: branch.repo, forest: forest) }
        }
    }

    @ViewBuilder
    private func content(_ since: ReviewSince, _ mark: ReviewSince.Mark) -> some View {
        let e = since.trusted(branch.name, tip: branch.tip)
        let answers = e.map(ReviewSince.answers) ?? []
        if mark != .same || !answers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("since your review").foregroundStyle(theme.inkFaint)
                    if let word = mark.word {
                        Text(word).foregroundStyle(mark == .eyes ? theme.ember : mark.loud ? theme.goldLeaf : theme.inkDim)
                    }
                    if let why = e?.why, !why.isEmpty { Text(why).foregroundStyle(theme.inkDim).lineLimit(1).help(why) }
                }
                if let e {
                    ForEach(answers, id: \.answer.id) { n, a in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.place(n)).foregroundStyle(theme.inkFaint).lineLimit(1)
                            Text(a.state).foregroundStyle(ReviewSince.needsEyes(a, in: e) ? theme.ember : theme.inkFaint)
                            Text(a.text).foregroundStyle(theme.inkDim).lineLimit(2)
                        }
                        .help(n.said.map { "you said: \($0)" } ?? "")
                    }
                }
            }
            .font(Theme.text(11.5))
            .padding(.top, 2)
        }
    }

    /// Where a note was made, as a reader finds it in the file list: the file's name and line.
    static func place(_ n: ReviewSince.Note) -> String {
        guard let file = n.file else { return n.id }
        return (file as NSString).lastPathComponent + (n.line.map { ":\($0)" } ?? "")
    }
}
